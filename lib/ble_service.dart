import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';
import 'app_constants.dart';

// Must match the ESP32 BLE backup firmware.
const String esp32DeviceName = 'ESP32_SmartHome';
const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String commandCharUuid = 'd8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f';

// Backwards-compatible aliases used by older dashboard code.
const String sensorCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String lightCharUuid = commandCharUuid;

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});

class BleService {
  BluetoothDevice? _device;
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
  bool get isConnected => _currentStatus == BleStatus.connected || _currentStatus == BleStatus.dataUpdated;

  bool _isUserCancelledBluetoothError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('notfounderror') ||
        message.contains('user cancelled') ||
        message.contains('user canceled') ||
        message.contains('cancelled the requestdevice') ||
        message.contains('canceled the requestdevice') ||
        message.contains('requestdevice() chooser') ||
        message.contains('bluetooth device chooser');
  }

  BleService() {
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (_disposed) return;
      if (state != BluetoothAdapterState.on) {
        _disconnect();
        _updateStatus(BleStatus.adapterOff);
      } else if (_currentStatus == BleStatus.adapterOff) {
        _updateStatus(BleStatus.disconnected);
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

    StreamSubscription<List<ScanResult>>? scanSub;
    final foundDevice = Completer<BluetoothDevice?>();

    try {
      await _safeStopScan();

      scanSub = FlutterBluePlus.scanResults.listen(
            (results) {
          for (final result in results) {
            final name = result.device.platformName.isNotEmpty
                ? result.device.platformName
                : result.advertisementData.advName;
            final hasService = result.advertisementData.serviceUuids
                .map((e) => e.toString().toLowerCase())
                .contains(serviceUuid.toLowerCase());

            if ((name == esp32DeviceName || hasService) && !foundDevice.isCompleted) {
              foundDevice.complete(result.device);
              break;
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!foundDevice.isCompleted) {
            foundDevice.completeError(error, stackTrace);
          }
        },
      );

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        withServices: kIsWeb ? [Guid(serviceUuid)] : [],
      );

      _device = await foundDevice.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } catch (e) {
      // On Flutter Web, closing/cancelling the browser Bluetooth chooser throws
      // NotFoundError. This is a normal user action, not a real app error.
      if (_isUserCancelledBluetoothError(e)) {
        logDebug('BLE scan cancelled by user: $e');
        _updateStatus(BleStatus.disconnected);
        return;
      }
      logDebug('BLE scan error: $e');
      _updateStatus(BleStatus.error);
      return;
    } finally {
      await scanSub?.cancel();
      await _safeStopScan();
    }

    if (_device == null) {
      _updateStatus(BleStatus.notFound);
      return;
    }

    _updateStatus(BleStatus.connecting);
    try {
      await _device!.connect(autoConnect: false).timeout(const Duration(seconds: 6));
      await _connectionSub?.cancel();
      _connectionSub = _device!.connectionState.listen((state) {
        if (_disposed) return;
        if (state == BluetoothConnectionState.disconnected) {
          _disconnect(clearDevice: true);
          _updateStatus(BleStatus.disconnected);
        }
      });

      final services = await _device!.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() != serviceUuid.toLowerCase()) continue;
        for (final char in service.characteristics) {
          final uuid = char.uuid.toString().toLowerCase();
          if (uuid == commandCharUuid.toLowerCase()) {
            _commandChar = char;
          }
        }
      }

      if (_commandChar == null) {
        throw StateError('BLE backup command characteristic not found');
      }

      _updateStatus(BleStatus.connected);
      await readSensorData();
      unawaited(refreshDevices());
      _startSensorPolling();
    } catch (e) {
      if (_isUserCancelledBluetoothError(e)) {
        logDebug('BLE connection cancelled by user: $e');
        _disconnect();
        _updateStatus(BleStatus.disconnected);
        return;
      }
      logDebug('BLE connection error: $e');
      _disconnect();
      _updateStatus(BleStatus.error);
    }
  }

  Future<Map<String, dynamic>> sendCommand(
      Map<String, dynamic> command, {
        Duration timeout = AppConfig.mediumTimeout,
      }) async {
    if (!isConnected || _commandChar == null) {
      throw StateError('BLE is not connected');
    }
    if (_commandBusy) {
      throw StateError('Another BLE command is already running');
    }

    _commandBusy = true;
    final expectedCmd = (command['cmd'] ?? '').toString();

    try {
      await _commandChar!.write(
        utf8.encode(jsonEncode(command)),
        withoutResponse: false,
      );

      final deadline = DateTime.now().add(timeout);
      Map<String, dynamic>? last;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 60));
        final value = await _commandChar!.read();
        final text = utf8.decode(value, allowMalformed: true).trim();
        if (text.isEmpty) continue;
        final decoded = jsonDecode(text);
        if (decoded is! Map) continue;
        last = decoded.cast<String, dynamic>();
        final responseCmd = (last['cmd'] ?? '').toString();
        if (expectedCmd.isEmpty || responseCmd.isEmpty || responseCmd == expectedCmd) {
          if (last['ok'] == false) {
            throw Exception(last['error'] ?? last['message'] ?? 'BLE command failed');
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
    _sensorPollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      readSensorData();
    });
  }

  Future<void> readSensorData() async {
    if (!isConnected) return;
    try {
      final data = await sendCommand({'cmd': 'status'}, timeout: AppConfig.shortTimeout);
      final temp = data['temp'] ?? data['temperature'];
      final hum = data['hum'] ?? data['humidity'];
      final flame = data['flame'];
      if (temp is num) temperature = temp.toDouble();
      if (hum is num) humidity = hum.toDouble();
      if (flame is bool) flameDetected = flame;
      _updateStatus(BleStatus.dataUpdated);
    } catch (e) {
      logDebug('BLE status read skipped: $e');
    }
  }

  Future<void> refreshDevices() async {
    if (!isConnected) return;
    try {
      final response = await sendCommand({'cmd': 'get_devices'}, timeout: AppConfig.mediumTimeout);
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
      logDebug('BLE get devices skipped: $e');
    }
  }

  Future<void> readLightStates() => refreshDevices();

  Future<void> disconnect() async {
    _disconnect(clearDevice: true);
    _updateStatus(BleStatus.disconnected);
  }

  Future<bool> controlDevice({required String id, required bool state}) async {
    final response = await sendCommand({
      'cmd': 'set_device',
      'id': id,
      'state': state,
    }, timeout: AppConfig.bleControlTimeout);
    if (response['ok'] == true) {
      for (final d in devices) {
        if ((d['id'] ?? '').toString() == id) {
          d['state'] = state;
          final room = (d['room'] ?? '').toString();
          if (room.isNotEmpty) lights[room] = state;
        }
      }
      _updateStatus(BleStatus.dataUpdated);
      return true;
    }
    return false;
  }

  Future<void> setLightState(String room, bool state) async {
    final response = await sendCommand({
      'cmd': 'set_room',
      'room': room,
      'state': state,
    }, timeout: AppConfig.bleControlTimeout);
    if (response['ok'] == true) {
      lights[room] = state;
      _updateStatus(BleStatus.dataUpdated);
    }
  }

  Future<bool> editGpio(String id, int gpio) async {
    final response = await sendCommand({
      'cmd': 'edit_gpio',
      'id': id,
      'gpio': gpio,
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<bool> connectWifi(String ssid, String password) async {
    final response = await sendCommand({
      'cmd': 'wifi_connect',
      'ssid': ssid,
      'password': password,
    }, timeout: AppConfig.mediumTimeout);
    return response['ok'] == true;
  }

  Future<List<Map<String, dynamic>>> scanWifi() async {
    final response = await sendCommand({
      'cmd': 'wifi_scan',
    }, timeout: const Duration(seconds: 10));

    final networks = response['networks'];
    if (networks is List) {
      return networks
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<bool> forgetWifi() async {
    try {
      final response = await sendCommand({
        'cmd': 'forget_wifi',
      }, timeout: AppConfig.mediumTimeout);
      return response['ok'] == true;
    } catch (_) {
      // Older experimental firmware used wifi_forget. Keep this fallback so
      // mixed app/firmware versions do not fail at compile/runtime.
      final response = await sendCommand({
        'cmd': 'wifi_forget',
      }, timeout: AppConfig.mediumTimeout);
      return response['ok'] == true;
    }
  }


  Future<void> _safeStopScan() async {
    try {
      final scanning = await FlutterBluePlus.isScanning
          .first
          .timeout(const Duration(milliseconds: 250), onTimeout: () => false);
      if (scanning) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      // FlutterBluePlus may print "already stopped" on some platforms. It is harmless.
      logDebug('BLE stopScan ignored: $e');
    }
  }

  void _disconnect({bool clearDevice = true}) {
    _sensorPollTimer?.cancel();
    _sensorPollTimer = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    if (clearDevice) {
      final device = _device;
      _device = null;
      if (device != null) {
        unawaited(device.disconnect().catchError((_) {}));
      }
    }
    _commandChar = null;
  }

  void _updateStatus(BleStatus status) {
    if (_disposed) return;
    _currentStatus = status;
    if (!_stateController.isClosed) {
      _stateController.add(status);
    }
  }

  void dispose() {
    _disposed = true;
    _sensorPollTimer?.cancel();
    _connectionSub?.cancel();
    _adapterSub?.cancel();
    final device = _device;
    _device = null;
    if (device != null) {
      unawaited(device.disconnect().catchError((_) {}));
    }
    unawaited(_safeStopScan());
    _stateController.close();
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
        return 'BLE Backup Connected';
      case BleStatus.adapterOff:
        return 'Bluetooth off';
      case BleStatus.error:
        return 'BLE error';
    }
  }
}
