import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:riverpod/riverpod.dart';

// Constants – must match the ESP32 firmware
const String esp32DeviceName = "ESP32_SmartHome";
const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String sensorCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const String lightCharUuid = "d8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f";

final bleServiceProvider = Provider<BleService>((ref) => BleService());

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _sensorChar;
  BluetoothCharacteristic? _lightChar;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _sensorPollTimer;

  // Current values (cached)
  double temperature = 0.0;
  double humidity = 0.0;
  bool flameDetected = false;
  Map<String, bool> lights = {'room1': false, 'room2': false, 'room3': false};

  // State stream for UI
  final _stateController = StreamController<BleStatus>.broadcast();
  Stream<BleStatus> get statusStream => _stateController.stream;
  BleStatus _currentStatus = BleStatus.disconnected;
  BleStatus get currentStatus => _currentStatus;

  BleService() {
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _autoConnect();
      } else {
        _disconnect();
        _updateStatus(BleStatus.adapterOff);
      }
    });
  }

  // Public: start connection
  Future<void> connect() async {
    if (_currentStatus == BleStatus.connected || _currentStatus == BleStatus.connecting) return;

    _updateStatus(BleStatus.scanning);
    await FlutterBluePlus.stopScan();

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    bool found = false;

    await for (var scanResult in FlutterBluePlus.scanResults) {
      for (var r in scanResult) {
        if (r.device.name == esp32DeviceName) {
          found = true;
          _device = r.device;
          FlutterBluePlus.stopScan();
          break;
        }
      }
      if (found) break;
    }

    if (_device == null) {
      _updateStatus(BleStatus.notFound);
      return;
    }

    _updateStatus(BleStatus.connecting);
    try {
      await _device!.connect();
      _connectionSub = _device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _disconnect();
          _updateStatus(BleStatus.disconnected);
          _autoConnect();
        }
      });

      // ✅ FIX: discoverServices returns a Future<List<BluetoothService>>
      final List<BluetoothService> services = await _device!.discoverServices();
      for (var service in services) {
        if (service.uuid.toString() == serviceUuid) {
          for (var char in service.characteristics) {
            if (char.uuid.toString() == sensorCharUuid) {
              _sensorChar = char;
            } else if (char.uuid.toString() == lightCharUuid) {
              _lightChar = char;
            }
          }
        }
      }

      if (_sensorChar == null || _lightChar == null) {
        throw Exception("Required characteristics not found");
      }

      _updateStatus(BleStatus.connected);
      _startSensorPolling();
      await readLightStates(); // initial light read
    } catch (e) {
      _updateStatus(BleStatus.error);
      print("BLE connection error: $e");
    }
  }

  void _startSensorPolling() {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      await readSensorData();
    });
    readSensorData();
  }

  Future<void> readSensorData() async {
    if (_currentStatus != BleStatus.connected || _sensorChar == null) return;
    try {
      List<int> value = await _sensorChar!.read();
      String json = String.fromCharCodes(value);
      final tempMatch = RegExp(r'"temp":([\d.]+)').firstMatch(json);
      final humMatch = RegExp(r'"hum":([\d.]+)').firstMatch(json);
      final flameMatch = RegExp(r'"flame":(true|false)').firstMatch(json);
      if (tempMatch != null) temperature = double.parse(tempMatch.group(1)!);
      if (humMatch != null) humidity = double.parse(humMatch.group(1)!);
      if (flameMatch != null) flameDetected = flameMatch.group(1) == 'true';
      _stateController.add(BleStatus.dataUpdated);
    } catch (e) {
      print("Read sensor error: $e");
    }
  }

  Future<void> readLightStates() async {
    if (_currentStatus != BleStatus.connected || _lightChar == null) return;
    try {
      List<int> value = await _lightChar!.read();
      String json = String.fromCharCodes(value);
      final room1 = RegExp(r'"room1":(true|false)').firstMatch(json);
      final room2 = RegExp(r'"room2":(true|false)').firstMatch(json);
      final room3 = RegExp(r'"room3":(true|false)').firstMatch(json);
      if (room1 != null) lights['room1'] = room1.group(1) == 'true';
      if (room2 != null) lights['room2'] = room2.group(1) == 'true';
      if (room3 != null) lights['room3'] = room3.group(1) == 'true';
      _stateController.add(BleStatus.dataUpdated);
    } catch (e) {
      print("Read light states error: $e");
    }
  }

  Future<void> setLightState(String room, bool state) async {
    if (_currentStatus != BleStatus.connected || _lightChar == null) return;
    final command = "$room:${state ? "on" : "off"}";
    try {
      await _lightChar!.write(command.codeUnits);
      lights[room] = state;
      _stateController.add(BleStatus.dataUpdated);
    } catch (e) {
      print("Write light error: $e");
      rethrow;
    }
  }

  void _autoConnect() {
    if (_currentStatus == BleStatus.disconnected) {
      connect();
    }
  }

  void _disconnect() {
    _sensorPollTimer?.cancel();
    _connectionSub?.cancel();
    _device?.disconnect();
    _device = null;
    _sensorChar = null;
    _lightChar = null;
  }

  void _updateStatus(BleStatus status) {
    _currentStatus = status;
    _stateController.add(status);
  }

  void dispose() {
    _sensorPollTimer?.cancel();
    _connectionSub?.cancel();
    _stateController.close();
    FlutterBluePlus.stopScan();
  }
}

enum BleStatus {
  disconnected,
  scanning,
  notFound,
  connecting,
  connected,
  dataUpdated,
  adapterOff,
  error,
}

extension BleStatusExt on BleStatus {
  String get message {
    switch (this) {
      case BleStatus.disconnected: return "Disconnected";
      case BleStatus.scanning: return "Scanning...";
      case BleStatus.notFound: return "ESP32 not found";
      case BleStatus.connecting: return "Connecting...";
      case BleStatus.connected: return "BLE Connected";
      case BleStatus.dataUpdated: return "BLE Connected";
      case BleStatus.adapterOff: return "Bluetooth off";
      case BleStatus.error: return "BLE error";
    }
  }
}