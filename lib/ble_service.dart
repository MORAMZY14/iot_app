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
const String commandCharUuid = 'd8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f';

// Backwards-compatible alias used by older dashboard code.
const String lightCharUuid = commandCharUuid;

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _sensorChar;
  BluetoothCharacteristic? _commandChar;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _sensorPollTimer;
  bool _disposed = false;
  bool _commandBusy = false;

  double temperature = 0.0;
  double humidity = 0.0;
  bool flameDetected = false;
  Map<String, bool> lights = <String, bool>{};
  List<Map<String, dynamic>> devices = <Map<String, dynamic>>[];

  final _stateController = StreamController<BleStatus>.broadcast();
  Stream<BleStatus> get statusStream => _stateController.stream;

  BleStatus _currentStatus = BleStatus.disconnected;
  BleStatus get currentStatus => _currentStatus;
  bool get isConnected => _currentStatus == BleStatus.connected && _commandChar != null;

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
        final name = result.device.platformName.isNotEmpty
            ? result.device.platformName
            : result.device.advName;
        if ((name == esp32DeviceName || name.contains('ESP32')) &&
            !foundDevice.isCompleted) {
          foundDevice.complete(result.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
      _device = await foundDevice.future.timeout(
        const Duration(seconds: 7),
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
      await _device!.connect(autoConnect: false).timeout(const Duration(seconds: 10));
      if (!kIsWeb) {
        try {
          await _device!.requestMtu(512).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }

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
        if (service.uuid.toString().toLowerCase() != serviceUuid) continue;
        for (final char in service.characteristics) {
          final uuid = char.uuid.toString().toLowerCase();
          if (uuid == sensorCharUuid) {
            _sensorChar = char;
          } else if (uuid == commandCharUuid) {
            _commandChar = char;
          }
        }
      }

      if (_sensorChar == null || _commandChar == null) {
        throw StateError('Required BLE characteristics not found');
      }

      try {
        await _sensorChar!.setNotifyValue(true);
      } catch (_) {}
      try {
        await _commandChar!.setNotifyValue(true);
      } catch (_) {}

      _updateStatus(BleStatus.connected);
      _startSensorPolling();
      await refreshDevices();
    } catch (e) {
      logDebug('BLE connection error: $e');
      _disconnect();
      _updateStatus(BleStatus.error);
    }
  }

  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isConnected || _commandChar == null) {
      throw StateError('BLE is not connected');
    }
    if (_commandBusy) {
      throw StateError('Another BLE command is already running');
    }

    _commandBusy = true;
    final expectedCmd = (command['cmd'] ?? command['action'] ?? '').toString();
    try {
      await _commandChar!.write(
        utf8.encode(jsonEncode(command)),
        withoutResponse: false,
      );

      final deadline = DateTime.now().add(timeout);
      Map<String, dynamic>? last;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 220));
        final value = await _commandChar!.read();
        final text = utf8.decode(value, allowMalformed: true).trim();
        if (text.isEmpty) continue;
        final decoded = jsonDecode(text);
        if (decoded is! Map) continue;
        last = decoded.cast<String, dynamic>();
        final responseCmd = (last['cmd'] ?? '').toString();
        if (expectedCmd.isEmpty || responseCmd.isEmpty || responseCmd == expectedCmd) {
          if (last['ok'] == false) {
            throw Exception(last['message'] ?? 'BLE command failed');
          }
          return last;
        }
      }
      throw TimeoutException('BLE command timed out. Last response: $last');
    } finally {
      _commandBusy = false;
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

  Future<void> refreshDevices() async {
    if (!isConnected) return;
    try {
      final response = await sendCommand({'cmd': 'get_devices'});
      final rawDevices = response['devices'];
      if (rawDevices is List) {
        devices = rawDevices
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        lights = <String, bool>{};
        for (final d in devices) {
          final key = (d['room'] ?? d['id'] ?? '').toString();
          if (key.isNotEmpty) lights[key] = d['state'] == true;
        }
      }
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('BLE refresh devices error: $e');
    }
  }

  Future<void> readLightStates() => refreshDevices();

  Future<void> setDeviceState(String id, bool state) async {
    final response = await sendCommand({
      'cmd': 'set_device',
      'id': id,
      'state': state,
    });
    if (response['ok'] == false) {
      throw Exception(response['message'] ?? 'BLE device command failed');
    }
    for (final d in devices) {
      if (d['id'] == id) d['state'] = state;
    }
    _updateStatus(BleStatus.dataUpdated);
  }

  Future<void> setLightState(String roomOrId, bool state) async {
    final matched = devices.where((d) => d['id'] == roomOrId || d['room'] == roomOrId);
    if (matched.isNotEmpty) {
      await setDeviceState(matched.first['id'].toString(), state);
      lights[roomOrId] = state;
      return;
    }

    // Backward compatibility for older firmware.
    if (_commandChar == null) return;
    await _commandChar!.write(utf8.encode('$roomOrId:${state ? 'on' : 'off'}'));
    lights[roomOrId] = state;
    _updateStatus(BleStatus.dataUpdated);
  }

  Future<List<Map<String, dynamic>>> scanWifi() async {
    final response = await sendCommand(
      {'cmd': 'wifi_scan'},
      timeout: const Duration(seconds: 15),
    );
    final networks = response['networks'];
    if (networks is List) {
      return networks.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<void> connectWifi(String ssid, String password) async {
    await sendCommand({
      'cmd': 'wifi_connect',
      'ssid': ssid,
      'password': password,
    });
  }

  Future<void> forgetWifi() async {
    await sendCommand({'cmd': 'wifi_forget'});
  }

  Future<void> addDevice({
    required String name,
    required int type,
    required int gpio,
    required String room,
  }) async {
    await sendCommand({
      'cmd': 'add_device',
      'name': name,
      'type': type,
      'gpio': gpio,
      'room': room,
    });
    await refreshDevices();
  }

  Future<void> removeDevice(String id) async {
    await sendCommand({'cmd': 'remove_device', 'id': id});
    await refreshDevices();
  }

  Future<void> editGpio(String id, int gpio) async {
    await sendCommand({'cmd': 'edit_gpio', 'id': id, 'gpio': gpio});
    await refreshDevices();
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
    _commandChar = null;
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
