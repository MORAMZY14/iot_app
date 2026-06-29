import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';

// Constants – must match the ESP32 firmware.
const String esp32DeviceName = 'ESP32_SmartHome';
const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String sensorCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String lightCharUuid = 'd8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f';

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _sensorChar;
  BluetoothCharacteristic? _lightChar;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _sensorPollTimer;
  bool _disposed = false;

  double temperature = 0.0;
  double humidity = 0.0;
  bool flameDetected = false;
  Map<String, bool> lights = <String, bool>{};

  final _stateController = StreamController<BleStatus>.broadcast();
  Stream<BleStatus> get statusStream => _stateController.stream;

  BleStatus _currentStatus = BleStatus.disconnected;
  BleStatus get currentStatus => _currentStatus;

  BleService() {
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (_disposed) return;
      if (state == BluetoothAdapterState.on) {
        // On Flutter Web, startScan opens the browser Bluetooth chooser.
        // Browsers require this to happen from a user gesture, so never
        // auto-open it during app startup or page navigation.
        if (!kIsWeb) {
          _autoConnect();
        }
      } else {
        _disconnect();
        _updateStatus(BleStatus.adapterOff);
      }
    });
  }

  Future<void> connect() async {
    if (_disposed ||
        _currentStatus == BleStatus.connected ||
        _currentStatus == BleStatus.connecting ||
        _currentStatus == BleStatus.scanning) {
      return;
    }

    _updateStatus(BleStatus.scanning);
    await _safeStopScan();

    StreamSubscription<List<ScanResult>>? scanSub;
    final foundDevice = Completer<BluetoothDevice?>();

    scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.name;
        if (name == esp32DeviceName && !foundDevice.isCompleted) {
          foundDevice.complete(result.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      _device = await foundDevice.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => null,
      );
    } catch (e) {
      // Common on Flutter Web when the user closes/cancels the browser
      // Bluetooth chooser. Treat it as a normal cancel, not a crash.
      logDebug('BLE scan cancelled or failed: $e');
      _updateStatus(BleStatus.disconnected);
      return;
    } finally {
      await scanSub.cancel();
      await _safeStopScan();
    }

    if (_device == null) {
      _updateStatus(BleStatus.notFound);
      return;
    }

    _updateStatus(BleStatus.connecting);
    try {
      await _device!.connect().timeout(const Duration(seconds: 10));
      await _connectionSub?.cancel();
      _connectionSub = _device!.connectionState.listen((state) {
        if (_disposed) return;
        if (state == BluetoothConnectionState.disconnected) {
          _disconnect();
          _updateStatus(BleStatus.disconnected);
          if (!kIsWeb) {
            _autoConnect();
          }
        }
      });

      final services = await _device!.discoverServices();
      for (final service in services) {
        if (service.uuid.toString() != serviceUuid) continue;
        for (final char in service.characteristics) {
          final uuid = char.uuid.toString();
          if (uuid == sensorCharUuid) {
            _sensorChar = char;
          } else if (uuid == lightCharUuid) {
            _lightChar = char;
          }
        }
      }

      if (_sensorChar == null || _lightChar == null) {
        throw StateError('Required BLE characteristics not found');
      }

      _updateStatus(BleStatus.connected);
      _startSensorPolling();
      await readLightStates();
    } catch (e) {
      logDebug('BLE connection error: $e');
      _disconnect();
      _updateStatus(BleStatus.error);
    }
  }

  void _startSensorPolling() {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      readSensorData();
    });
    readSensorData();
  }

  Future<void> readSensorData() async {
    if (_currentStatus != BleStatus.connected || _sensorChar == null) return;
    try {
      final value = await _sensorChar!.read();
      final payload = utf8.decode(value, allowMalformed: true);
      final data = jsonDecode(payload) as Map<String, dynamic>;

      final temp = data['temp'] ?? data['temperature'];
      final hum = data['hum'] ?? data['humidity'];
      final flame = data['flame'];

      if (temp is num) temperature = temp.toDouble();
      if (hum is num) humidity = hum.toDouble();
      if (flame is bool) flameDetected = flame;

      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('Read sensor error: $e');
    }
  }

  Future<void> readLightStates() async {
    if (_currentStatus != BleStatus.connected || _lightChar == null) return;
    try {
      final value = await _lightChar!.read();
      final payload = utf8.decode(value, allowMalformed: true);
      final data = jsonDecode(payload) as Map<String, dynamic>;
      lights = data.map((key, value) => MapEntry(key, value == true));
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('Read light states error: $e');
    }
  }

  Future<void> setLightState(String room, bool state) async {
    if (_currentStatus != BleStatus.connected || _lightChar == null) return;
    final command = '$room:${state ? 'on' : 'off'}';
    try {
      await _lightChar!.write(utf8.encode(command));
      lights[room] = state;
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('Write light error: $e');
      rethrow;
    }
  }

  void _autoConnect() {
    if (_disposed || _currentStatus != BleStatus.disconnected) return;
    unawaited(connect());
  }

  void _disconnect() {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = null;
    unawaited(_connectionSub?.cancel() ?? Future<void>.value());
    _connectionSub = null;
    final device = _device;
    _device = null;
    _sensorChar = null;
    _lightChar = null;
    if (device != null) {
      unawaited(device.disconnect().catchError((_) {}));
    }
  }

  void _updateStatus(BleStatus status) {
    if (_disposed) return;
    _currentStatus = status;
    if (!_stateController.isClosed) {
      _stateController.add(status);
    }
  }

  Future<void> _safeStopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      logDebug('BLE stopScan ignored: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _sensorPollTimer?.cancel();
    unawaited(_connectionSub?.cancel() ?? Future<void>.value());
    unawaited(_adapterSub?.cancel() ?? Future<void>.value());
    final device = _device;
    _device = null;
    if (device != null) {
      unawaited(device.disconnect().catchError((_) {}));
    }
    _stateController.close();
    unawaited(_safeStopScan());
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
      case BleStatus.disconnected:
        return 'Disconnected';
      case BleStatus.scanning:
        return 'Scanning...';
      case BleStatus.notFound:
        return 'ESP32 not found';
      case BleStatus.connecting:
        return 'Connecting...';
      case BleStatus.connected:
      case BleStatus.dataUpdated:
        return 'BLE Connected';
      case BleStatus.adapterOff:
        return 'Bluetooth off';
      case BleStatus.error:
        return 'BLE error';
    }
  }
}
