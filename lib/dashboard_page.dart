import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'ble_service.dart';
import 'auth_service.dart';
import 'app_logger.dart';
import 'app_constants.dart';

// ────────────────────────────────────────────────────────────
// 0. THEME MANAGEMENT
// ────────────────────────────────────────────────────────────
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// Nav index lives in a provider so theme changes don't reset it
final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

// Bump this value after adding/editing/removing rooms or devices.
// HomeContent is keyed from it, so the dashboard reloads immediately.
final dashboardRefreshTickProvider = StateProvider<int>((ref) => 0);

final lightTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorSchemeSeed: const Color(0xFF6C63FF),
  scaffoldBackgroundColor: const Color(0xFFF0F2FF),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
);

final darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorSchemeSeed: const Color(0xFF6C63FF),
  scaffoldBackgroundColor: const Color(0xFF0B0D1A),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
);

// ────────────────────────────────────────────────────────────
// 1. DESIGN TOKENS
// ────────────────────────────────────────────────────────────
class _DT {
  static const purple = Color(0xFF6C63FF);
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = Color(0xFF64B5F6);
  static const red = Color(0xFFFF5252);
  static const espConnected = Color(0xFF4DFFA0);
}

// ────────────────────────────────────────────────────────────
// 2. RESPONSIVE HELPER
// ────────────────────────────────────────────────────────────
class ResponsiveHelper {
  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
          MediaQuery.of(context).size.width < 1200;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1200;

  static double getPadding(BuildContext context) {
    if (isDesktop(context)) return 40.0;
    if (isTablet(context)) return 30.0;
    return 20.0;
  }

  static int getGridColumns(BuildContext context) {
    if (isDesktop(context)) return 4;
    if (isTablet(context)) return 3;
    return 2;
  }
}

// ────────────────────────────────────────────────────────────
// 3. CACHED HTTP SERVICE
// ────────────────────────────────────────────────────────────
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  final Map<String, _CacheEntry> _cache = {};
  final Duration _ttl = const Duration(seconds: 5);

  void set(String key, dynamic data) {
    _cache[key] = _CacheEntry(data, DateTime.now().add(_ttl));
  }

  dynamic get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiry)) {
      _cache.remove(key);
      return null;
    }
    return entry.data;
  }

  void clear() => _cache.clear();
}

class _CacheEntry {
  final dynamic data;
  final DateTime expiry;
  _CacheEntry(this.data, this.expiry);
}

// ────────────────────────────────────────────────────────────
// 4. ESP32 DEVICE MANAGEMENT SERVICE (FIXED)
// ────────────────────────────────────────────────────────────
class ESP32DeviceService {
  final String esp32Ip;
  final BleService bleService;

  ESP32DeviceService(this.esp32Ip, this.bleService);

  // Read devices from Firebase - FIXED null handling
  Future<Map<String, dynamic>> getDevices() async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.get(
        Uri.parse('$databaseUrl/smartHome/$uid/devices.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final String responseBody = response.body;
        if (responseBody.isEmpty || responseBody == 'null') {
          return {'devices': []};
        }

        final dynamic data = jsonDecode(responseBody);
        if (data == null) {
          return {'devices': []};
        }

        final Map<String, dynamic> dataMap = data as Map<String, dynamic>;
        final List<Map<String, dynamic>> devicesList = [];
        dataMap.forEach((key, value) {
          if (value is Map) {
            devicesList.add(value.cast<String, dynamic>());
          }
        });
        return {'devices': devicesList};
      }
      return {'devices': []};
    } catch (e) {
      logDebug('Error getting devices: $e');
      return {'devices': []};
    }
  }

  // Add device via Firebase. GPIO uniqueness is GLOBAL across all rooms.
  Future<bool> addDevice({
    required String name,
    required int type,
    required int gpio,
    required String room,
  }) async {
    try {
      final usedGPIOs = await getUsedGPIOs();
      if (usedGPIOs.contains(gpio)) {
        logDebug('GPIO $gpio is already used by another device.');
        return false;
      }

      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final String id = 'dev_${DateTime.now().millisecondsSinceEpoch}';

      final deviceData = {
        'id': id,
        'name': name,
        'type': type,
        'gpio': gpio,
        'room': room,
        'state': false,
        'enabled': true,
      };

      final response = await http.put(
        Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(deviceData),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error adding device: $e');
      return false;
    }
  }

  // Edit GPIO via Firebase. The new GPIO must not be used by any other device.
  Future<bool> editDeviceGPIO({
    required String id,
    required int newGpio,
  }) async {
    try {
      final usedGPIOs = await getUsedGPIOs(excludingDeviceId: id);
      if (usedGPIOs.contains(newGpio)) {
        logDebug('GPIO $newGpio is already used by another device.');
        return false;
      }

      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.patch(
        Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'gpio': newGpio}),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error editing GPIO: $e');
      return false;
    }
  }

  // Control device quickly. If the phone can reach the ESP32 locally,
  // use the ESP32 HTTP API first for near-instant GPIO switching. The ESP32
  // will update Firebase after switching the GPIO. If local access fails,
  // Firebase is used as the fallback path.
  Future<bool> controlDevice({
    required String id,
    required bool state,
  }) async {
    // Backup path: if BLE is already connected, use it first.
    // This keeps control working even when internet/router/Firebase is unavailable.
    if (bleService.isConnected) {
      try {
        final ok = await bleService.controlDevice(id: id, state: state)
            .timeout(const Duration(milliseconds: 900));
        if (ok) return true;
      } catch (e) {
        logDebug('BLE backup control failed, trying local Wi-Fi/Firebase: $e');
      }
    }

    try {
      final localResponse = await http.post(
        Uri.parse('http://$esp32Ip/api/devices/control'),
        body: {
          'id': id,
          'state': state ? 'true' : 'false',
        },
      ).timeout(const Duration(milliseconds: 650));

      if (localResponse.statusCode == 200) {
        return true;
      }
    } catch (_) {
      // Local ESP32 API is optional. This will fail when the phone is not on
      // the same Wi-Fi network, so fall back to Firebase below.
    }

    return _controlDeviceViaFirebase(id: id, state: state);
  }

  Future<bool> _controlDeviceViaFirebase({
    required String id,
    required bool state,
  }) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.patch(
        Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'state': state}),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error controlling device: $e');
      return false;
    }
  }

  // Remove device via Firebase
  Future<bool> removeDevice(String id) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.delete(
        Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
      ).timeout(const Duration(seconds: 3));

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error removing device: $e');
      return false;
    }
  }

  // Save rooms to Firebase
  Future<bool> saveRooms(List<String> rooms) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.put(
        Uri.parse('$databaseUrl/smartHome/$uid/rooms.json'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(rooms),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      logDebug('Error saving rooms: $e');
      return false;
    }
  }



  Future<bool> renameRoomInDevices({
    required String oldRoom,
    required String newRoom,
  }) async {
    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final devicesResult = await getDevices();
      final devices = devicesResult['devices'] as List? ?? [];
      bool ok = true;

      for (final device in devices) {
        if (device is Map && device['room'] == oldRoom && device['id'] != null) {
          final id = device['id'].toString();
          final response = await http.patch(
            Uri.parse('$databaseUrl/smartHome/$uid/devices/$id.json'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'room': newRoom}),
          ).timeout(const Duration(seconds: 5));
          ok = ok && response.statusCode == 200;
        }
      }

      return ok;
    } catch (e) {
      logDebug('Error renaming room in devices: $e');
      return false;
    }
  }
  // Get rooms from Firebase. Important: do NOT invent default rooms.
  // The dashboard should show no rooms until the user creates one.
  Future<List<String>> getRooms() async {
    List<String> normalizeRooms(dynamic data) {
      final Set<String> rooms = {};

      if (data is List) {
        for (final item in data) {
          final room = item?.toString().trim() ?? '';
          if (room.isNotEmpty) rooms.add(room);
        }
      } else if (data is Map) {
        for (final item in data.values) {
          final room = item?.toString().trim() ?? '';
          if (room.isNotEmpty) rooms.add(room);
        }
      }

      final sorted = rooms.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return sorted;
    }

    try {
      final String databaseUrl = AppConfig.databaseUrl;
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.get(
        Uri.parse('$databaseUrl/smartHome/$uid/rooms.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200 && response.body.isNotEmpty && response.body != 'null') {
        final rooms = normalizeRooms(jsonDecode(response.body));
        if (rooms.isNotEmpty) return rooms;
      }

      // Migration fallback only: if old devices already have room names but no
      // /rooms node exists yet, show those rooms. Do not create fake defaults.
      final devicesResponse = await http.get(
        Uri.parse('$databaseUrl/smartHome/$uid/devices.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 3));

      if (devicesResponse.statusCode == 200 && devicesResponse.body.isNotEmpty && devicesResponse.body != 'null') {
        final dynamic data = jsonDecode(devicesResponse.body);
        final Set<String> rooms = {};
        if (data is Map) {
          data.forEach((_, value) {
            if (value is Map && value['room'] != null) {
              final room = value['room'].toString().trim();
              if (room.isNotEmpty) rooms.add(room);
            }
          });
        }
        final roomsList = rooms.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (roomsList.isNotEmpty) {
          await saveRooms(roomsList);
          return roomsList;
        }
      }

      return [];
    } catch (e) {
      logDebug('Error getting rooms: $e');
      return [];
    }
  }

  Future<Set<int>> getUsedGPIOs({String? excludingDeviceId}) async {
    final result = await getDevices();
    final devices = result['devices'] as List? ?? [];
    final used = <int>{};

    for (final device in devices) {
      if (device is! Map) continue;

      final id = device['id']?.toString();
      if (excludingDeviceId != null && id == excludingDeviceId) continue;

      final gpioValue = device['gpio'];
      final gpio = gpioValue is int ? gpioValue : int.tryParse(gpioValue?.toString() ?? '');
      if (gpio != null) used.add(gpio);
    }

    return used;
  }

  // GPIOs shown in menus. This combines the ESP scan with Firebase devices,
  // then removes every pin already used anywhere, even in another room.
  Future<List<int>> getSelectableGPIOs({String? excludingDeviceId, int? currentGpio}) async {
    final scannedPins = await getAvailableGPIOs();
    final usedPins = await getUsedGPIOs(excludingDeviceId: excludingDeviceId);

    final pins = <int>{..._getDefaultGPIOs(), ...scannedPins};
    if (currentGpio != null) pins.add(currentGpio);

    final selectable = pins
        .where((pin) => !usedPins.contains(pin) || pin == currentGpio)
        .toList()
      ..sort();

    return selectable;
  }

  Future<List<int>> getAvailableGPIOs() async {
    try {
      final response = await http.get(
        Uri.parse('http://$esp32Ip/api/gpio/scan'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final available = data['available'] as List? ?? [];
        return available.map((e) => e['pin'] as int).toList();
      }
      return _getDefaultGPIOs();
    } catch (e) {
      logDebug('Error getting GPIOs (using defaults): $e');
      return _getDefaultGPIOs();
    }
  }

  List<int> _getDefaultGPIOs() {
    return [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
  }

  Future<List<Map<String, dynamic>>> getDeviceTypes() async {
    try {
      final response = await http.get(
        Uri.parse('http://$esp32Ip/api/devicetypes'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['types'] as List? ?? []).map((e) => e as Map<String, dynamic>).toList();
      }
      return [
        {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
        {'type': 1, 'name': 'Fan', 'icon': 'fan'},
        {'type': 2, 'name': 'Switch', 'icon': 'power'},
        {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
      ];
    } catch (e) {
      return [
        {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
        {'type': 1, 'name': 'Fan', 'icon': 'fan'},
        {'type': 2, 'name': 'Switch', 'icon': 'power'},
        {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
      ];
    }
  }
}

// ────────────────────────────────────────────────────────────
// 5. ESP32 IP PROVIDER
// ────────────────────────────────────────────────────────────
final userEsp32CodeProvider = FutureProvider<String?>((ref) async {
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;

  if (user != null) {
    final String databaseUrl = AppConfig.databaseUrl;
    final response = await http.get(
      Uri.parse('$databaseUrl/users/${user.uid}/esp32Code.json'),
      headers: {'Cache-Control': 'no-cache'},
    ).timeout(const Duration(seconds: 3));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data as String?;
    }
  }
  return null;
});

final esp32IpProvider = FutureProvider<String>((ref) async {
  final code = await ref.watch(userEsp32CodeProvider.future);
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;

  if (code == null || code.isEmpty || user == null) {
    return '192.168.1.9';
  }

  logDebug('🔎 Looking up IP for ESP32 Code: $code');

  final String databaseUrl = AppConfig.databaseUrl;

  try {
    final response = await http.get(
      Uri.parse('$databaseUrl/esp_public/$code/status.json'),
      headers: {'Cache-Control': 'no-cache'},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data != null && data['ip'] != null) {
        return data['ip'] as String;
      }
    }
  } catch (e) {
    logDebug('Error fetching IP from esp_public: $e');
  }

  try {
    final response = await http.get(
      Uri.parse('$databaseUrl/smartHome/${user.uid}/status.json'),
      headers: {'Cache-Control': 'no-cache'},
    ).timeout(const Duration(seconds: 3));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data != null && data['uniqueCode'] == code) {
        return data['ip'] ?? '192.168.1.9';
      }
    }
  } catch (e) {
    logDebug('Error fetching IP from user node: $e');
  }

  return '192.168.1.9';
});

final esp32DeviceServiceProvider = FutureProvider<ESP32DeviceService>((ref) async {
  final ip = await ref.watch(esp32IpProvider.future);
  final bleService = ref.read(bleServiceProvider);
  return ESP32DeviceService(ip, bleService);
});

// ────────────────────────────────────────────────────────────
// 6. HTTP POLLING SERVICE WITH CACHING
// ────────────────────────────────────────────────────────────
final databaseUrlProvider = Provider((ref) =>
AppConfig.databaseUrl);

final httpDataProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final url = ref.watch(databaseUrlProvider);
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;
  final cache = CacheService();

  if (user == null) {
    return {
      'sensors': {'temperature': 0.0, 'humidity': 0.0, 'flame': false},
      'lights': {},
      'status': {'online': false},
    };
  }

  final cacheKey = 'smartHome_${user.uid}';
  final cached = cache.get(cacheKey);
  if (cached != null) {
    return cached as Map<String, dynamic>;
  }

  int retryCount = 0;
  final maxRetries = 3;

  while (retryCount < maxRetries) {
    try {
      final response = await http.get(
        Uri.parse('$url/smartHome/${user.uid}.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);
        if (jsonData != null) {
          Map<String, dynamic> processedData = {};

          if (jsonData.containsKey('temperature') || jsonData.containsKey('flame')) {
            processedData['sensors'] = {
              'temperature': jsonData['temperature'] ?? 0.0,
              'humidity': jsonData['humidity'] ?? 0.0,
              'flame': jsonData['flame'] ?? false,
            };

            if (jsonData.containsKey('lights')) {
              processedData['lights'] = jsonData['lights'];
            }
            if (jsonData.containsKey('status')) {
              processedData['status'] = jsonData['status'];
            }
          } else {
            processedData = jsonData;
          }

          if (!processedData.containsKey('sensors')) {
            processedData['sensors'] = {
              'temperature': 0.0,
              'humidity': 0.0,
              'flame': false,
            };
          }

          if (!processedData.containsKey('lights')) {
            processedData['lights'] = {};
          }

          if (!processedData.containsKey('status')) {
            processedData['status'] = {'online': false};
          }

          final status = processedData['status'] as Map? ?? {};
          int lastSeen = status['lastSeen'] as int? ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          // ESP heartbeat is every 30 seconds, so a 10-second online window
          // makes the UI falsely show Offline between heartbeats.
          status['online'] = (now - lastSeen) < 90 && lastSeen > 0;
          processedData['status'] = status;

          cache.set(cacheKey, processedData);
          return processedData;
        }
      }
    } catch (_) {
      retryCount++;
      if (retryCount < maxRetries) {
        await Future.delayed(Duration(milliseconds: 500 * retryCount));
      }
    }
  }
  return {
    'sensors': {'temperature': 0.0, 'humidity': 0.0, 'flame': false},
    'lights': {},
    'status': {'online': false},
  };
});

// ────────────────────────────────────────────────────────────
// 7. BLE + HTTP MERGED DATA PROVIDER
// ────────────────────────────────────────────────────────────
final bleServiceProvider = Provider<BleService>((ref) => BleService());

final smartHomeDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final controller = StreamController<Map<String, dynamic>>();
  late StreamSubscription bleStatusSub;
  Timer? httpTimer;
  final cache = CacheService();

  final authService = ref.watch(authServiceProvider).requireValue;
  final user = authService.currentUser;

  Map<String, dynamic> currentData = {
    'sensors': {'temperature': 0.0, 'humidity': 0.0, 'flame': false},
    'lights': {},
    'status': {'online': false},
  };

  controller.add(Map.from(currentData));

  void updateFromBle() {
    if (bleService.currentStatus == BleStatus.connected) {
      currentData['sensors'] = {
        'temperature': bleService.temperature,
        'humidity': bleService.humidity,
        'flame': bleService.flameDetected,
      };
      currentData['lights'] = Map.from(bleService.lights);
      currentData['status']['online'] = true;
      if (user != null) {
        cache.set('bleData_${user.uid}', currentData);
      }
      if (!controller.isClosed) controller.add(Map.from(currentData));
    }
  }

  Future<void> fetchHttpData() async {
    try {
      final httpData = await ref.read(httpDataProvider.future);
      if (bleService.currentStatus != BleStatus.connected) {
        if (user != null) {
          final cachedBle = cache.get('bleData_${user.uid}');
          if (cachedBle != null) {
            currentData = Map<String, dynamic>.from(cachedBle as Map);
            currentData['status'] = httpData['status'] ?? currentData['status'];
            if (!controller.isClosed) controller.add(Map.from(currentData));
            return;
          }
        }
        currentData = httpData;
        if (!controller.isClosed) controller.add(Map.from(currentData));
      } else if (httpData.containsKey('status')) {
        currentData['status'] = httpData['status'];
        if (!controller.isClosed) controller.add(Map.from(currentData));
      }
    } catch (e) {
      if (!controller.isClosed && currentData.isNotEmpty) {
        controller.add(Map.from(currentData));
      }
    }
  }

  if (user != null) {
    final cachedData = cache.get('bleData_${user.uid}');
    if (cachedData != null) {
      currentData = Map<String, dynamic>.from(cachedData as Map);
      Future.microtask(() {
        if (!controller.isClosed) controller.add(Map.from(currentData));
      });
    }
  }

  bleStatusSub = bleService.statusStream.listen((status) {
    if (status == BleStatus.connected || status == BleStatus.dataUpdated) {
      updateFromBle();
    } else if (status == BleStatus.disconnected) {
      ref.invalidate(httpDataProvider);
    }
  });

  fetchHttpData();

  httpTimer = Timer.periodic(const Duration(seconds: 5), (_) => fetchHttpData());

  Future<void> connectWithRetry() async {
    int attempts = 0;
    while (attempts < 3) {
      try {
        await bleService.connect();
        break;
      } catch (_) {
        attempts++;
        if (attempts < 3) await Future.delayed(Duration(seconds: attempts));
      }
    }
  }

  connectWithRetry();

  ref.onDispose(() {
    bleStatusSub.cancel();
    httpTimer?.cancel();
    controller.close();
    bleService.dispose();
  });

  return controller.stream;
});

// ────────────────────────────────────────────────────────────
// 8. LIGHT TOGGLE SERVICE
// ────────────────────────────────────────────────────────────
final lightToggleProvider = Provider((ref) => LightToggleService(ref));

class LightToggleService {
  final Ref _ref;
  LightToggleService(this._ref);

  void _patchCache(String cacheKey, String room, bool value) {
    final cached = CacheService().get(cacheKey);
    if (cached == null) return;
    final updated = Map<String, dynamic>.from(cached as Map);
    final lights = Map<String, dynamic>.from(updated['lights'] ?? {});
    lights[room] = value;
    updated['lights'] = lights;
    CacheService().set(cacheKey, updated);
  }

  void _revertCache(String cacheKey, String room, bool originalValue) {
    _patchCache(cacheKey, room, originalValue);
  }

  Future<void> toggle(String room, bool value, BuildContext context) async {
    final bleService = _ref.read(bleServiceProvider);
    final url = _ref.read(databaseUrlProvider);
    final authService = _ref.watch(authServiceProvider).requireValue;
    final user = authService.currentUser;

    if (user == null) {
      if (context.mounted) {
        _showSnack(context, '❌ User not authenticated', color: _DT.red);
      }
      return;
    }

    final cacheKey = 'smartHome_${user.uid}';
    final bleCacheKey = 'bleData_${user.uid}';

    _patchCache(cacheKey, room, value);
    _patchCache(bleCacheKey, room, value);

    if (bleService.currentStatus == BleStatus.connected) {
      try {
        await bleService.setLightState(room, value);
        return;
      } catch (e) {
        if (context.mounted) {
          _showSnack(context, 'BLE error, trying Wi-Fi…',
              color: Colors.orange);
        }
      }
    }

    try {
      final response = await http
          .patch(
        Uri.parse('$url/smartHome/${user.uid}/lights.json'),
        body: jsonEncode({room: value}),
      )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      _revertCache(cacheKey, room, !value);
      _revertCache(bleCacheKey, room, !value);
      if (context.mounted) {
        _showSnack(context, 'Failed to toggle light', color: _DT.red);
      }
      rethrow;
    }
  }
}

void _showSnack(BuildContext context, String msg,
    {Color color = Colors.white}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: color.withValues(alpha: 0.9),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    margin: const EdgeInsets.all(16),
    duration: const Duration(seconds: 2),
  ));
}

// ────────────────────────────────────────────────────────────
// 9. WALLPAPER BACKGROUND
// ────────────────────────────────────────────────────────────
class _WallpaperBackground extends StatelessWidget {
  final Widget child;
  const _WallpaperBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final w = MediaQuery.of(context).size.width;

    return RepaintBoundary(
      child: Stack(children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [Color(0xFF0B0D1A), Color(0xFF0F1228), Color(0xFF0B0D1A)]
                  : const [Color(0xFFF0F2FF), Color(0xFFEEEBFF), Color(0xFFF0F4FF)],
            ),
          ),
        ),
        Positioned(
            top: -100,
            left: -80,
            child: _Blob(
                color: isDark ? const Color(0xFF1A1060) : const Color(0xFFCCC8FF),
                size: w * 0.9)),
        Positioned(
            top: 300,
            right: -100,
            child: _Blob(
                color: isDark ? const Color(0xFF2A0D50) : const Color(0xFFE8D8FF),
                size: w * 0.75)),
        Positioned(
            bottom: 80,
            left: 0,
            child: _Blob(
                color: isDark ? const Color(0xFF0A2A1A) : const Color(0xFFBEF0D8),
                size: w * 0.6)),
        child,
      ]),
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0)],
      ),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 10. DASHBOARD PAGE
// ────────────────────────────────────────────────────────────
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage>
    with SingleTickerProviderStateMixin {
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = const [
      _HomeContentWrapper(),
      _EnergyScreen(),
      _AlertsScreen(),
      _SettingsScreen(),
    ];
  }

  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connect();
    ref.invalidate(httpDataProvider);

    final authService = ref.read(authServiceProvider).requireValue;
    if (mounted) _showSnack(context, 'Refreshed ✓', color: _DT.green);
  }

  void _showQuickActionDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _QuickActionDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bleService = ref.watch(bleServiceProvider);
    final selectedIndex = ref.watch(selectedNavIndexProvider);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: _GlassAppBar(
        onRefresh: _manualRefresh,
        bleStatus: bleService.currentStatus,
        onConnectBLE: () => bleService.connect(),
      ),
      body: _WallpaperBackground(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                ),
                child: RepaintBoundary(child: child),
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(selectedIndex),
            child: _pages[selectedIndex],
          ),
        ),
      ),
      floatingActionButton: isDesktop
          ? null
          : _PurpleFab(onTap: () {
        HapticFeedback.mediumImpact();
        _showQuickActionDialog(context);
      }),
      floatingActionButtonLocation:
      isDesktop ? null : FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: isDesktop
          ? null
          : Padding(
        padding:
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: _GlassBottomNav(
          selectedIndex: selectedIndex,
          onTap: (i) {
            ref.read(selectedNavIndexProvider.notifier).state = i;
          },
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 11. PASSWORD DIALOG
// ────────────────────────────────────────────────────────────
class _PasswordDialog extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback? onCancel;

  const _PasswordDialog({
    required this.onSuccess,
    this.onCancel,
  });

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  bool _obscureText = true;
  String _errorMessage = '';

  void _verifyPassword() {
    if (_passwordController.text == '1234') {
      widget.onSuccess();
      Navigator.pop(context);
    } else {
      setState(() {
        _errorMessage = 'Incorrect password. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.transparent,
      child: _GCard(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DT.purple.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: _DT.purple,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter Password',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This action requires admin password',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordController,
              obscureText: _obscureText,
              decoration: InputDecoration(
                hintText: 'Enter password',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _DT.purple, width: 2),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureText ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  onPressed: () => setState(() => _obscureText = !_obscureText),
                ),
                errorText: _errorMessage.isNotEmpty ? _errorMessage : null,
              ),
              onSubmitted: (_) => _verifyPassword(),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      widget.onCancel?.call();
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _verifyPassword,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _DT.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Verify',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }
}

// ────────────────────────────────────────────────────────────
// 12. EDIT GPIO DIALOG
// ────────────────────────────────────────────────────────────
class _EditGPIODialog extends ConsumerStatefulWidget {
  final String deviceId;
  final String deviceName;
  final int currentGpio;

  const _EditGPIODialog({
    required this.deviceId,
    required this.deviceName,
    required this.currentGpio,
  });

  @override
  ConsumerState<_EditGPIODialog> createState() => _EditGPIODialogState();
}

class _EditGPIODialogState extends ConsumerState<_EditGPIODialog> {
  late int _selectedGpio;
  bool _isLoading = false;
  List<int> _availableGPIOs = [];

  @override
  void initState() {
    super.initState();
    _selectedGpio = widget.currentGpio;
    _loadAvailableGPIOs();
  }

  Future<void> _loadAvailableGPIOs() async {
    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final gpios = await service.getSelectableGPIOs(
        excludingDeviceId: widget.deviceId,
        currentGpio: widget.currentGpio,
      );
      if (!mounted) return;
      setState(() {
        _availableGPIOs = gpios;
        _selectedGpio = gpios.contains(widget.currentGpio)
            ? widget.currentGpio
            : (gpios.isNotEmpty ? gpios.first : widget.currentGpio);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availableGPIOs = [widget.currentGpio];
        _selectedGpio = widget.currentGpio;
      });
    }
  }

  Future<void> _updateGPIO() async {
    if (_selectedGpio == widget.currentGpio) {
      if (mounted) {
        _showSnack(context, 'No change in GPIO', color: Colors.orange);
        Navigator.pop(context);
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final success = await service.editDeviceGPIO(
        id: widget.deviceId,
        newGpio: _selectedGpio,
      );

      setState(() => _isLoading = false);

      if (mounted) {
        if (success) {
          ref.read(dashboardRefreshTickProvider.notifier).state++;
          Navigator.pop(context, true);
          await _refreshDevices();
          _showSnack(context, '✅ GPIO updated successfully!', color: _DT.green);
        } else {
          _showSnack(context, '❌ Failed to update GPIO - Check if pin is available', color: _DT.red);
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
      }
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final result = await service.getDevices();
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      logDebug('Error refreshing devices: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.transparent,
      child: _GCard(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DT.purple.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.edit_rounded,
                color: _DT.purple,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Edit GPIO',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Device: ${widget.deviceName}',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _selectedGpio,
                  isExpanded: true,
                  items: _availableGPIOs.map((gpio) {
                    return DropdownMenuItem(
                      value: gpio,
                      child: Row(
                        children: [
                          Text('GPIO $gpio'),
                          if (gpio == widget.currentGpio) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: _DT.purple.withValues(alpha: 0.15),
                              ),
                              child: const Text(
                                'Current',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _DT.purple,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: _isLoading || _availableGPIOs.isEmpty
                      ? null
                      : (value) {
                    if (value != null) {
                      setState(() => _selectedGpio = value);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _updateGPIO,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _DT.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : const Text(
                      'Update GPIO',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 13. QUICK ACTION DIALOG
// ────────────────────────────────────────────────────────────
class _QuickActionDialog extends ConsumerStatefulWidget {
  const _QuickActionDialog();

  @override
  ConsumerState<_QuickActionDialog> createState() => _QuickActionDialogState();
}

class _QuickActionDialogState extends ConsumerState<_QuickActionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int? _selectedGpio;

  int _selectedType = 0;
  String _selectedRoom = '';
  bool _isLoading = false;

  List<String> _rooms = [];
  List<Map<String, dynamic>> _deviceTypes = [];
  List<int> _availableGPIOs = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _isLoading = true);

    final fallbackTypes = <Map<String, dynamic>>[
      {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
      {'type': 1, 'name': 'Fan', 'icon': 'fan'},
      {'type': 2, 'name': 'Switch', 'icon': 'power'},
      {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
    ];

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);

      List<int> gpios;
      List<String> rooms;
      List<Map<String, dynamic>> types;

      try {
        gpios = await service.getSelectableGPIOs().timeout(const Duration(seconds: 3));
      } catch (e) {
        logDebug('GPIO fetch failed: $e');
        gpios = [];
      }

      try {
        rooms = await service.getRooms().timeout(const Duration(seconds: 3));
      } catch (e) {
        logDebug('Rooms fetch failed: $e');
        rooms = [];
      }

      try {
        types = await service.getDeviceTypes().timeout(const Duration(seconds: 3));
        if (types.isEmpty) types = fallbackTypes;
      } catch (e) {
        logDebug('Types fetch failed: $e');
        types = fallbackTypes;
      }

      if (!mounted) return;
      setState(() {
        _availableGPIOs = gpios;
        _selectedGpio = gpios.isNotEmpty ? gpios.first : null;
        _rooms = rooms;
        _selectedRoom = rooms.isNotEmpty ? rooms.first : '';
        _deviceTypes = types;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _availableGPIOs = [];
        _selectedGpio = null;
        _rooms = [];
        _selectedRoom = '';
        _deviceTypes = fallbackTypes;
      });
      _showSnack(context, '⚠️ Could not load GPIOs. Connect the ESP32 or refresh.', color: Colors.orange);
    }
  }

  Future<void> _showRoomManagementDialog() async {
    final updatedRooms = await showDialog<List<String>>(
      context: context,
      builder: (context) => _RoomManagementDialog(
        rooms: _rooms,
        onRoomsUpdated: (updatedRooms) async {
          if (!mounted) return;
          setState(() {
            _rooms = updatedRooms;
            _selectedRoom = _rooms.contains(_selectedRoom)
                ? _selectedRoom
                : (_rooms.isNotEmpty ? _rooms.first : '');
          });
          ref.read(dashboardRefreshTickProvider.notifier).state++;
        },
      ),
    );

    if (updatedRooms != null && mounted) {
      setState(() {
        _rooms = updatedRooms;
        _selectedRoom = _rooms.contains(_selectedRoom)
            ? _selectedRoom
            : (_rooms.isNotEmpty ? _rooms.first : '');
      });
    }
  }

  Future<void> _addDevice() async {
    if (_rooms.isEmpty || _selectedRoom.isEmpty) {
      _showSnack(context, 'Add a room first, then add devices inside it.', color: Colors.orange);
      await _showRoomManagementDialog();
      return;
    }

    if (_selectedGpio == null || !_availableGPIOs.contains(_selectedGpio)) {
      _showSnack(context, 'No free GPIO is available. Edit or remove another device first.', color: Colors.orange);
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);

      // Re-check Firebase right before saving. This prevents duplicate GPIOs
      // if another room/device was added before the dialog refreshed.
      final latestFreeGPIOs = await service.getSelectableGPIOs();
      if (!latestFreeGPIOs.contains(_selectedGpio)) {
        if (!mounted) return;
        setState(() {
          _availableGPIOs = latestFreeGPIOs;
          _selectedGpio = latestFreeGPIOs.isNotEmpty ? latestFreeGPIOs.first : null;
          _isLoading = false;
        });
        _showSnack(context, 'GPIO already used by another device. Choose another pin.', color: Colors.orange);
        return;
      }

      final success = await service.addDevice(
        name: _nameController.text.trim(),
        type: _selectedType,
        gpio: _selectedGpio!,
        room: _selectedRoom,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (success) {
        ref.read(dashboardRefreshTickProvider.notifier).state++;
        ref.invalidate(httpDataProvider);
        Navigator.pop(context);
        _showSnack(context, '✅ Device added successfully!', color: _DT.green);
      } else {
        _showSnack(context, '❌ Failed to add device', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88,
          ),
          decoration: const BoxDecoration(color: Colors.transparent),
          child: _GCard(
            padding: const EdgeInsets.all(24),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Add New Device',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.meeting_room_rounded),
                          onPressed: _isLoading ? null : _showRoomManagementDialog,
                          tooltip: 'Manage Rooms',
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _rooms.isEmpty
                      ? 'Create your first room before adding devices.'
                      : 'Connect a new device to your ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 20),
                Flexible(
                  child: _isLoading && _deviceTypes.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: _DT.purple))
                      : SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_rooms.isEmpty) ...[
                            _GCard(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.info_outline_rounded, color: _DT.purple),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'No rooms yet',
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Add a room first. After that, it will appear on the dashboard even before adding devices.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: _showRoomManagementDialog,
                                      icon: const Icon(Icons.add_rounded),
                                      label: const Text('Add Room'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _DT.purple,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],
                          Text(
                            'Device Name',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _nameController,
                            enabled: _rooms.isNotEmpty && !_isLoading,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              hintText: 'e.g. Living Room Lamp',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Please enter a device name';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Device Type',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 48,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _deviceTypes.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                              itemBuilder: (context, index) {
                                final type = _deviceTypes[index];
                                final isSelected = _selectedType == type['type'];
                                return GestureDetector(
                                  onTap: _rooms.isEmpty || _isLoading
                                      ? null
                                      : () => setState(() => _selectedType = type['type'] as int),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(20),
                                      color: isSelected ? _DT.purple : Colors.transparent,
                                      border: Border.all(
                                        color: isSelected
                                            ? _DT.purple
                                            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _getIconForType(type['type'] as int),
                                          size: 18,
                                          color: isSelected ? Colors.white : _DT.purple,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          type['name'] as String,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: isSelected
                                                ? Colors.white
                                                : Theme.of(context).colorScheme.onSurface,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'GPIO Pin',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<int>(
                            value: _availableGPIOs.contains(_selectedGpio) ? _selectedGpio : null,
                            isExpanded: true,
                            decoration: InputDecoration(
                              hintText: _availableGPIOs.isEmpty
                                  ? 'No free GPIOs available'
                                  : 'Select GPIO',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            ),
                            items: _availableGPIOs.map((gpio) {
                              return DropdownMenuItem<int>(
                                value: gpio,
                                child: Text('GPIO $gpio'),
                              );
                            }).toList(),
                            onChanged: _rooms.isEmpty || _isLoading || _availableGPIOs.isEmpty
                                ? null
                                : (value) => setState(() => _selectedGpio = value),
                            validator: (value) {
                              if (value == null) return 'Choose a free GPIO';
                              if (!_availableGPIOs.contains(value)) return 'GPIO $value is already used';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Room',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _rooms.contains(_selectedRoom) ? _selectedRoom : null,
                                isExpanded: true,
                                hint: const Text('Select Room'),
                                items: _rooms.map((room) {
                                  return DropdownMenuItem(value: room, child: Text(room));
                                }).toList(),
                                onChanged: _rooms.isEmpty || _isLoading
                                    ? null
                                    : (value) {
                                  if (value != null) setState(() => _selectedRoom = value);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: _DT.purple.withValues(alpha: 0.08),
                              border: Border.all(color: _DT.purple.withValues(alpha: 0.15)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline_rounded, color: _DT.purple, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _availableGPIOs.isEmpty
                                        ? 'No free GPIOs available. Remove a device or change its GPIO first.'
                                        : 'Free GPIOs: ${_availableGPIOs.join(", ")}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _addDevice,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _DT.purple,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                elevation: 0,
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                                  : const Text(
                                'Add Device',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getIconForType(int type) {
    switch (type) {
      case 0:
        return Icons.lightbulb_rounded;
      case 1:
        return Icons.air_rounded;
      case 2:
        return Icons.power_settings_new_rounded;
      case 3:
        return Icons.electrical_services_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}
// ────────────────────────────────────────────────────────────
// 14. ROOM MANAGEMENT DIALOG
// ────────────────────────────────────────────────────────────
class _RoomManagementDialog extends ConsumerStatefulWidget {
  final List<String> rooms;
  final Function(List<String>) onRoomsUpdated;

  const _RoomManagementDialog({
    required this.rooms,
    required this.onRoomsUpdated,
  });

  @override
  ConsumerState<_RoomManagementDialog> createState() => _RoomManagementDialogState();
}

class _RoomManagementDialogState extends ConsumerState<_RoomManagementDialog> {
  late List<String> _rooms;
  final TextEditingController _newRoomController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _rooms = List<String>.from(widget.rooms)
      ..removeWhere((room) => room.trim().isEmpty)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<bool> _persistRooms(List<String> rooms) async {
    final service = await ref.read(esp32DeviceServiceProvider.future);
    final success = await service.saveRooms(rooms);
    if (success) {
      widget.onRoomsUpdated(List<String>.from(rooms));
      ref.read(dashboardRefreshTickProvider.notifier).state++;
    }
    return success;
  }

  Future<void> _addRoom() async {
    final name = _newRoomController.text.trim();
    if (name.isEmpty) return;

    final exists = _rooms.any((room) => room.toLowerCase() == name.toLowerCase());
    if (exists) {
      _showSnack(context, 'Room already exists', color: Colors.orange);
      return;
    }

    final previous = List<String>.from(_rooms);
    setState(() {
      _rooms.add(name);
      _rooms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _newRoomController.clear();
      _isSaving = true;
    });

    try {
      final success = await _persistRooms(_rooms);
      if (!mounted) return;
      if (success) {
        _showSnack(context, '✅ Room added: $name', color: _DT.green);
      } else {
        setState(() => _rooms = previous);
        _showSnack(context, '❌ Failed to save room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _editRoom(String oldRoom) async {
    final controller = TextEditingController(text: oldRoom);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Room name'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName == null || newName.isEmpty || newName == oldRoom) return;
    final exists = _rooms.any((room) => room != oldRoom && room.toLowerCase() == newName.toLowerCase());
    if (exists) {
      _showSnack(context, 'Room already exists', color: Colors.orange);
      return;
    }

    final previous = List<String>.from(_rooms);
    setState(() {
      final index = _rooms.indexOf(oldRoom);
      if (index != -1) _rooms[index] = newName;
      _rooms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _isSaving = true;
    });

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final roomsSaved = await service.saveRooms(_rooms);
      final devicesRenamed = await service.renameRoomInDevices(oldRoom: oldRoom, newRoom: newName);
      if (!mounted) return;

      if (roomsSaved && devicesRenamed) {
        widget.onRoomsUpdated(List<String>.from(_rooms));
        ref.read(dashboardRefreshTickProvider.notifier).state++;
        _showSnack(context, '✅ Room renamed', color: _DT.green);
      } else {
        setState(() => _rooms = previous);
        await service.saveRooms(previous);
        _showSnack(context, '❌ Failed to rename room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeRoom(String room) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Room'),
        content: Text(
          'Delete "$room" from the room list? Devices already assigned to this room will stay in Firebase, but the room tab will disappear until you add/rename it again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: _DT.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final previous = List<String>.from(_rooms);
    setState(() {
      _rooms.remove(room);
      _isSaving = true;
    });

    try {
      final success = await _persistRooms(_rooms);
      if (!mounted) return;
      if (success) {
        _showSnack(context, '🗑️ Room removed: $room', color: _DT.amber);
      } else {
        setState(() => _rooms = previous);
        _showSnack(context, '❌ Failed to remove room', color: _DT.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rooms = previous);
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _newRoomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Manage Rooms',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  _rooms.isEmpty ? 'No rooms yet' : '${_rooms.length} rooms total',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _newRoomController,
                        decoration: InputDecoration(
                          hintText: 'New room name',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        onFieldSubmitted: (_) => _addRoom(),
                        enabled: !_isSaving,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _isSaving ? null : _addRoom,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                          : const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: _rooms.isEmpty
                      ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Column(
                      children: [
                        Icon(
                          Icons.meeting_room_outlined,
                          size: 42,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25),
                        ),
                        const SizedBox(height: 10),
                        const Text('No rooms yet. Add your first room!'),
                      ],
                    ),
                  )
                      : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _rooms.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final room = _rooms[index];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.room_rounded, color: _DT.purple, size: 16),
                            const SizedBox(width: 8),
                            Expanded(child: Text(room)),
                            IconButton(
                              tooltip: 'Edit room',
                              icon: const Icon(Icons.edit_rounded, color: _DT.purple, size: 20),
                              onPressed: _isSaving ? null : () => _editRoom(room),
                            ),
                            IconButton(
                              tooltip: 'Delete room',
                              icon: const Icon(Icons.delete_rounded, color: _DT.red, size: 20),
                              onPressed: _isSaving ? null : () => _removeRoom(room),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context, List<String>.from(_rooms)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _DT.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 15. PURPLE FAB
// ────────────────────────────────────────────────────────────
class _PurpleFab extends StatelessWidget {
  final VoidCallback onTap;
  const _PurpleFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF8B7FFF), _DT.purple],
          ),
          boxShadow: [
            BoxShadow(
              color: _DT.purple.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 16. GLASS APP BAR
// ────────────────────────────────────────────────────────────
class _GlassAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _GlassAppBar({
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  void _toggleTheme(WidgetRef ref) {
    final current = ref.read(themeModeProvider);
    final next =
    current == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    ref.read(themeModeProvider.notifier).state = next;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final greeting = _getGreeting();

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.3),
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: const Padding(
              padding: EdgeInsets.only(left: 16),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: _DT.purple,
                child: Text('JD',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
              ),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_formattedDate(),
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.5),
                        fontWeight: FontWeight.w500)),
                Text(greeting,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.2)),
              ],
            ),
            actions: [
              _ABBtn(
                onTap: () => _toggleTheme(ref),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                  ),
                  child: Icon(
                    isDark
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                    size: 18,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _ABBtn(
                onTap: () {},
                child: Stack(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                    ),
                    child: Icon(Icons.notifications_outlined,
                        size: 18,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7)),
                  ),
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: CircleAvatar(
                      radius: 4,
                      backgroundColor: _DT.red,
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(0.5),
              child: Container(
                height: 0.5,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formattedDate() {
    final now = DateTime.now();
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday'
    ];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }

  String _getGreeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning ☀️';
    if (h < 17) return 'Good Afternoon 🌤';
    return 'Good Evening 🌙';
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 0.5);
}

class _ABBtn extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _ABBtn({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: onTap, child: child);
}

// ────────────────────────────────────────────────────────────
// 17. HOME CONTENT WRAPPER
// ────────────────────────────────────────────────────────────
class _HomeContentWrapper extends ConsumerStatefulWidget {
  const _HomeContentWrapper();

  @override
  ConsumerState<_HomeContentWrapper> createState() =>
      _HomeContentWrapperState();
}

class _HomeContentWrapperState extends ConsumerState<_HomeContentWrapper> {
  Future<void> _refresh() async {
    final ble = ref.read(bleServiceProvider);
    await ble.connect();
    ref.invalidate(httpDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(smartHomeDataProvider);
    final bleService = ref.watch(bleServiceProvider);
    final refreshTick = ref.watch(dashboardRefreshTickProvider);
    return _HomeContent(
      key: ValueKey(refreshTick),
      dataAsync: dataAsync,
      onRefresh: _refresh,
      bleStatus: bleService.currentStatus,
      onConnectBLE: () => bleService.connect(),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 18. HOME CONTENT - DYNAMIC DEVICES FROM ESP32
// ────────────────────────────────────────────────────────────
class _HomeContent extends ConsumerStatefulWidget {
  final AsyncValue<Map<String, dynamic>> dataAsync;
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _HomeContent({
    super.key,
    required this.dataAsync,
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  @override
  ConsumerState<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends ConsumerState<_HomeContent> {
  String _selectedRoom = '';
  List<String> _rooms = [];
  Map<String, dynamic> _esp32Devices = {'devices': []};
  bool _isLoadingDevices = false;
  bool _initialLoadDone = false;
  Timer? _refreshTimer;
  final Map<String, bool> _pendingDeviceStates = {};
  final Map<String, DateTime> _pendingDeviceStateTimes = {};
  final Set<String> _togglingDeviceIds = {};

  static const Duration _pendingStateHold = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _loadDashboardState();

    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) _loadDashboardStateSilently();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void updateDevices(Map<String, dynamic> newDevices) {
    setState(() {
      _esp32Devices = newDevices;
    });
  }

  List<String> _getVisibleRooms(List<dynamic> devicesList) {
    final Set<String> roomSet = {..._rooms};

    // Migration fallback only. If the user already has devices from the old
    // database but /rooms is empty, show their device rooms. No fake defaults.
    if (roomSet.isEmpty) {
      for (final device in devicesList) {
        if (device is Map && device['room'] != null) {
          final room = device['room'].toString().trim();
          if (room.isNotEmpty) roomSet.add(room);
        }
      }
    }

    return roomSet.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  String _effectiveSelectedRoom(List<String> rooms) {
    if (rooms.isEmpty) return '';
    if (rooms.contains(_selectedRoom)) return _selectedRoom;
    return rooms.first;
  }

  void _syncSelectedRoom(List<String> rooms) {
    final effective = _effectiveSelectedRoom(rooms);
    if (_selectedRoom != effective) {
      _selectedRoom = effective;
    }
  }

  List<Map<String, dynamic>> _applyPendingDeviceStates(List<dynamic> rawDevices) {
    final now = DateTime.now();
    final expired = <String>[];

    final devices = rawDevices
        .whereType<Map>()
        .map((device) {
      final updated = Map<String, dynamic>.from(device);
      final id = updated['id']?.toString() ?? '';
      if (id.isEmpty) return updated;

      final pendingState = _pendingDeviceStates[id];
      final pendingAt = _pendingDeviceStateTimes[id];
      if (pendingState == null || pendingAt == null) return updated;

      final fetchedState = updated['state'] as bool?;
      if (fetchedState == pendingState) {
        expired.add(id);
        return updated;
      }

      if (now.difference(pendingAt) <= _pendingStateHold) {
        updated['state'] = pendingState;
      } else {
        expired.add(id);
      }
      return updated;
    })
        .toList();

    for (final id in expired) {
      _pendingDeviceStates.remove(id);
      _pendingDeviceStateTimes.remove(id);
      _togglingDeviceIds.remove(id);
    }

    return devices;
  }

  bool _deviceListsEqual(List<dynamic> a, List<dynamic> b) {
    return jsonEncode(a) == jsonEncode(b);
  }

  Future<void> _loadDashboardState() async {
    if (_isLoadingDevices) return;
    setState(() => _isLoadingDevices = true);

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final result = await service.getDevices();
      final rooms = await service.getRooms();
      final devicesList = _applyPendingDeviceStates(result['devices'] as List? ?? []);
      final visibleRooms = {...rooms};
      if (visibleRooms.isEmpty) {
        for (final device in devicesList) {
          if (device is Map && device['room'] != null) {
            final room = device['room'].toString().trim();
            if (room.isNotEmpty) visibleRooms.add(room);
          }
        }
      }
      final sortedRooms = visibleRooms.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _esp32Devices = {'devices': devicesList};
        _rooms = sortedRooms;
        _syncSelectedRoom(_rooms);
        _isLoadingDevices = false;
        _initialLoadDone = true;
      });
    } catch (e) {
      logDebug('Error loading ESP32 dashboard state: $e');
      if (!mounted) return;
      setState(() {
        _esp32Devices = {'devices': []};
        _rooms = [];
        _selectedRoom = '';
        _isLoadingDevices = false;
        _initialLoadDone = true;
      });
    }
  }

  Future<void> _loadDashboardStateSilently() async {
    try {
      if (_togglingDeviceIds.isNotEmpty) {
        return;
      }

      final service = await ref.read(esp32DeviceServiceProvider.future);
      final result = await service.getDevices();
      final rooms = await service.getRooms();
      final mergedDevices = _applyPendingDeviceStates(result['devices'] as List? ?? []);
      if (!mounted) return;

      final currentDevices = _esp32Devices['devices'] as List? ?? [];
      final nextRooms = rooms.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final roomsChanged = jsonEncode(_rooms) != jsonEncode(nextRooms);
      final devicesChanged = !_deviceListsEqual(currentDevices, mergedDevices);
      if (!roomsChanged && !devicesChanged) return;

      setState(() {
        _esp32Devices = {'devices': mergedDevices};
        _rooms = nextRooms;
        _syncSelectedRoom(_getVisibleRooms(mergedDevices));
      });
    } catch (_) {
      // Silent fail for auto-refresh.
    }
  }

  Future<void> _refreshDevices() async {
    await _loadDashboardState();
    await widget.onRefresh();
  }

  void _showDeviceOptions(String deviceId, String deviceName, int currentGpio) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _GCard(
        padding: const EdgeInsets.all(20),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _DT.purple.withValues(alpha: 0.15),
              ),
              child: const Icon(Icons.devices_rounded, color: _DT.purple, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              deviceName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Current GPIO: $currentGpio',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            _OptionTile(
              icon: Icons.edit_rounded,
              title: 'Edit GPIO',
              subtitle: 'Change the GPIO pin',
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => _EditGPIODialog(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    currentGpio: currentGpio,
                  ),
                ).then((refreshed) {
                  if (refreshed == true) _loadDashboardState();
                });
              },
            ),
            const Divider(height: 1),
            _OptionTile(
              icon: Icons.delete_rounded,
              title: 'Remove Device',
              subtitle: 'Delete this device',
              onTap: () {
                Navigator.pop(context);
                _showRemoveDeviceDialog(deviceId, deviceName);
              },
              iconColor: _DT.red,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _showRemoveDeviceDialog(String deviceId, String deviceName) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _DT.red.withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.warning_rounded, color: _DT.red, size: 30),
              ),
              const SizedBox(height: 16),
              const Text(
                'Remove Device',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Are you sure you want to remove "$deviceName"?',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        try {
                          final service = await ref.read(esp32DeviceServiceProvider.future);
                          final success = await service.removeDevice(deviceId);
                          if (success) {
                            await _loadDashboardState();
                            _showSnack(context, '✅ Device removed', color: _DT.green);
                          } else {
                            _showSnack(context, '❌ Failed to remove device', color: _DT.red);
                          }
                        } catch (e) {
                          _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _controlDevice(String id, bool state) async {
    if (_togglingDeviceIds.contains(id)) return;

    final devices = List<dynamic>.from(_esp32Devices['devices'] as List? ?? []);
    final index = devices.indexWhere((d) => d is Map && d['id'] == id);
    final previousState = index != -1 && devices[index] is Map
        ? ((devices[index] as Map)['state'] as bool? ?? false)
        : !state;

    _pendingDeviceStates[id] = state;
    _pendingDeviceStateTimes[id] = DateTime.now();
    _togglingDeviceIds.add(id);

    if (index != -1 && devices[index] is Map) {
      final updatedDevice = Map<String, dynamic>.from(devices[index] as Map);
      updatedDevice['state'] = state;
      devices[index] = updatedDevice;
      setState(() => _esp32Devices = {'devices': devices});
    }

    try {
      final service = await ref.read(esp32DeviceServiceProvider.future);
      final success = await service.controlDevice(id: id, state: state);

      if (!mounted) return;

      if (!success) {
        _pendingDeviceStates.remove(id);
        _pendingDeviceStateTimes.remove(id);
        _togglingDeviceIds.remove(id);

        final revertedDevices = List<dynamic>.from(_esp32Devices['devices'] as List? ?? []);
        final revertIndex = revertedDevices.indexWhere((d) => d is Map && d['id'] == id);
        if (revertIndex != -1 && revertedDevices[revertIndex] is Map) {
          final revertedDevice = Map<String, dynamic>.from(revertedDevices[revertIndex] as Map);
          revertedDevice['state'] = previousState;
          revertedDevices[revertIndex] = revertedDevice;
          setState(() => _esp32Devices = {'devices': revertedDevices});
        }
        _showSnack(context, '❌ Failed to control device', color: _DT.red);
        return;
      }

      Future.delayed(const Duration(milliseconds: 1800), () {
        if (!mounted) return;
        if (_pendingDeviceStates[id] == state) {
          _pendingDeviceStates.remove(id);
          _pendingDeviceStateTimes.remove(id);
          _togglingDeviceIds.remove(id);
        }
      });
    } catch (e) {
      if (!mounted) return;
      _pendingDeviceStates.remove(id);
      _pendingDeviceStateTimes.remove(id);
      _togglingDeviceIds.remove(id);

      final revertedDevices = List<dynamic>.from(_esp32Devices['devices'] as List? ?? []);
      final revertIndex = revertedDevices.indexWhere((d) => d is Map && d['id'] == id);
      if (revertIndex != -1 && revertedDevices[revertIndex] is Map) {
        final revertedDevice = Map<String, dynamic>.from(revertedDevices[revertIndex] as Map);
        revertedDevice['state'] = previousState;
        revertedDevices[revertIndex] = revertedDevice;
        setState(() => _esp32Devices = {'devices': revertedDevices});
      }
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    if (!_initialLoadDone) {
      return const _SkeletonLoader();
    }

    return RefreshIndicator(
      onRefresh: _refreshDevices,
      displacement: 100,
      color: _DT.purple,
      child: widget.dataAsync.when(
        data: (data) {
          final sensors = (data['sensors'] as Map?) ?? {};
          final temp = (sensors['temperature'] ?? 0.0).toDouble();
          final hum = (sensors['humidity'] ?? 0.0).toDouble();
          final flame = sensors['flame'] == true;
          final status = (data['status'] as Map?) ?? {};
          final online = status['online'] ?? false;
          final ip = status['ip'] ?? '192.168.1.42';
          final ping = status['ping'] ?? 12;
          final rssi = status['rssi'] ?? -38;
          final energy = (data['energy'] as Map?) ?? {};
          final todayKw = (energy['today'] ?? 3.4).toDouble();

          final devicesList = _esp32Devices['devices'] as List? ?? [];
          final rooms = _getVisibleRooms(devicesList);
          final selectedRoom = _effectiveSelectedRoom(rooms);
          final roomDevices = selectedRoom.isEmpty
              ? <dynamic>[]
              : devicesList.where((d) => d is Map && d['room'] == selectedRoom).toList();

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + kToolbarHeight - 20,
              left: padding,
              right: padding,
              bottom: isDesktop ? 40 : 100,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _EspBar(
                  online: online,
                  ip: ip,
                  ping: ping,
                  rssi: rssi,
                  bleStatus: widget.bleStatus,
                  onConnectBLE: widget.onConnectBLE,
                ),
                const SizedBox(height: 14),
                _StatsRow(temp: temp, hum: hum, todayKw: todayKw),
                const SizedBox(height: 18),
                _FlameBanner(flame: flame),
                const SizedBox(height: 18),
                _RoomsHeader(
                  selectedRoom: selectedRoom,
                  onRoomSelected: (r) => setState(() => _selectedRoom = r),
                  rooms: rooms,
                ),
                const SizedBox(height: 14),
                if (_isLoadingDevices)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(color: _DT.purple),
                    ),
                  )
                else if (roomDevices.isEmpty)
                  _GCard(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      children: [
                        Icon(
                          rooms.isEmpty ? Icons.meeting_room_outlined : Icons.devices_rounded,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          rooms.isEmpty ? 'No rooms yet' : 'No devices in this room',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          rooms.isEmpty
                              ? 'Tap +, then Add Room, to create your first room.'
                              : 'Tap the + button to add a device',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: roomDevices.map((device) {
                      final map = device as Map;
                      final name = map['name'] as String? ?? 'Unknown';
                      final type = map['type'] as int? ?? 0;
                      final state = map['state'] as bool? ?? false;
                      final gpio = map['gpio'] as int? ?? 0;
                      final room = map['room'] as String? ?? '';
                      final id = map['id'] as String? ?? '';

                      final screenWidth = MediaQuery.of(context).size.width - (padding * 2);
                      final cardWidth = isDesktop ? (screenWidth - 36) / 4 : (screenWidth - 12) / 2;

                      return SizedBox(
                        width: cardWidth,
                        child: GestureDetector(
                          onTap: id.isEmpty ? null : () => _controlDevice(id, !state),
                          onLongPress: id.isEmpty ? null : () => _showDeviceOptions(id, name, gpio),
                          child: _DynamicDeviceCard(
                            name: name,
                            type: type,
                            state: state,
                            gpio: gpio,
                            room: room,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          );
        },
        loading: () => const _SkeletonLoader(),
        error: (err, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: _GCard(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, size: 48, color: _DT.red),
                const SizedBox(height: 16),
                Text(
                  'Something went wrong',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  err.toString(),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                _PillBtn(label: 'Try Again', onTap: _refreshDevices),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 19. DYNAMIC DEVICE CARD
// ────────────────────────────────────────────────────────────
class _DynamicDeviceCard extends StatelessWidget {
  final String name;
  final int type;
  final bool state;
  final int gpio;
  final String room;

  const _DynamicDeviceCard({
    required this.name,
    required this.type,
    required this.state,
    required this.gpio,
    required this.room,
  });

  IconData _getIcon() {
    switch (type) {
      case 0: return Icons.lightbulb_rounded;
      case 1: return Icons.air_rounded;
      case 2: return Icons.power_settings_new_rounded;
      case 3: return Icons.electrical_services_rounded;
      default: return Icons.devices_rounded;
    }
  }

  Color _getColor() {
    return state ? _DT.amber : Colors.grey;
  }

  String _getStatus() {
    return state ? 'On' : 'Off';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _getColor();

    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: state
              ? (isDark
              ? color.withValues(alpha: 0.12)
              : color.withValues(alpha: 0.08))
              : (isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.04)),
          border: Border.all(
            color: state
                ? color.withValues(alpha: 0.35)
                : (isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.07)),
            width: 1,
          ),
          boxShadow: state
              ? [
            BoxShadow(
              color: color.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 4),
            )
          ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: color.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    _getIcon(),
                    color: color,
                    size: 20,
                  ),
                ),
                Container(
                  width: 40,
                  height: 24,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: state
                        ? color.withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.1),
                    border: Border.all(
                      color: state
                          ? color.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.15),
                      width: 0.8,
                    ),
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 220),
                    alignment: state ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: state ? color : Colors.white.withValues(alpha: 0.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              '${_getStatus()} • GPIO $gpio',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: state ? color : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 20. ESP CONNECTION BAR
// ────────────────────────────────────────────────────────────
class _EspBar extends StatelessWidget {
  final bool online;
  final String ip;
  final int ping;
  final int rssi;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _EspBar({
    required this.online,
    required this.ip,
    required this.ping,
    required this.rssi,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  bool get _bleConnected =>
      bleStatus == BleStatus.connected || bleStatus == BleStatus.dataUpdated;

  bool get _bleBusy =>
      bleStatus == BleStatus.scanning || bleStatus == BleStatus.connecting;

  String get _bleStatusLabel {
    switch (bleStatus) {
      case BleStatus.disconnected:
        return 'BLE disconnected';
      case BleStatus.scanning:
        return 'Scanning BLE';
      case BleStatus.notFound:
        return 'ESP32 not found';
      case BleStatus.connecting:
        return 'Connecting BLE';
      case BleStatus.connected:
      case BleStatus.dataUpdated:
        return 'BLE connected';
      case BleStatus.adapterOff:
        return 'Bluetooth off';
      case BleStatus.error:
        return 'BLE error';
    }
  }

  String get _controlPath {
    if (_bleConnected) return 'Bluetooth backup active';
    if (online) return 'Wi-Fi / Firebase active';
    return 'Offline - connect Bluetooth backup';
  }

  @override
  Widget build(BuildContext context) {
    final wifiDotColor = online ? _DT.espConnected : _DT.red;
    final bleDotColor = _bleConnected
        ? _DT.blue
        : _bleBusy
        ? _DT.amber
        : Colors.grey;
    final surfaceText = Theme.of(context).colorScheme.onSurface;

    return _GCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _bleConnected
                    ? Icons.bluetooth_connected_rounded
                    : online
                    ? Icons.wifi_rounded
                    : Icons.cloud_off_rounded,
                size: 18,
                color: _bleConnected
                    ? _DT.blue
                    : online
                    ? _DT.espConnected
                    : _DT.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _controlPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (!_bleConnected)
                TextButton.icon(
                  onPressed: _bleBusy ? null : onConnectBLE,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: _bleBusy
                      ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.bluetooth_searching_rounded, size: 16),
                  label: Text(_bleBusy ? 'Connecting' : 'BLE'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _StatusPill(
                  label: online ? 'ESP online' : 'ESP offline',
                  icon: online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                  color: wifiDotColor,
                ),
                const SizedBox(width: 6),
                _StatusPill(
                  label: _bleConnected ? 'BLE connected' : _bleStatusLabel,
                  icon: _bleConnected
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_disabled_rounded,
                  color: bleDotColor,
                ),
                const SizedBox(width: 6),
                _MiniChip(label: ip, icon: Icons.settings_ethernet_rounded),
                const SizedBox(width: 6),
                _MiniChip(label: '${ping}ms', icon: Icons.timer_outlined),
                const SizedBox(width: 6),
                Row(children: [
                  Icon(Icons.wifi,
                      size: 14,
                      color: online ? _DT.espConnected : Colors.grey.shade600),
                  const SizedBox(width: 3),
                  Text('${rssi}dBm',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: online
                              ? _DT.espConnected
                              : Colors.grey.shade500)),
                ]),
              ],
            ),
          ),
          if (!online && !_bleConnected) ...[
            const SizedBox(height: 8),
            Text(
              'Internet is unavailable. Connect Bluetooth to control nearby devices.',
              style: TextStyle(
                fontSize: 12,
                height: 1.25,
                color: surfaceText.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _StatusPill({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.13),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 5)],
            ),
          ),
          const SizedBox(width: 5),
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
class _MiniChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _MiniChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.05),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.07),
          width: 0.5,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: Colors.grey),
        const SizedBox(width: 3),
        Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.grey)),
      ]),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 21. STATS ROW
// ────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final double temp;
  final double hum;
  final double todayKw;

  const _StatsRow({
    required this.temp,
    required this.hum,
    required this.todayKw,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: _StatTile(
        icon: Icons.thermostat_rounded,
        iconColor: const Color(0xFFFF6B6B),
        value: '${temp.toStringAsFixed(1)}°',
        label: 'Temp',
      )),
      const SizedBox(width: 10),
      Expanded(child: _StatTile(
        icon: Icons.water_drop_rounded,
        iconColor: _DT.blue,
        value: '${hum.toStringAsFixed(0)}%',
        label: 'Humid',
      )),
      const SizedBox(width: 10),
      Expanded(child: _StatTile(
        icon: Icons.bolt_rounded,
        iconColor: _DT.amber,
        value: '${todayKw.toStringAsFixed(1)}kW',
        label: 'Today',
      )),
    ]);
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      child: Column(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: iconColor.withValues(alpha: 0.15),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(height: 8),
        Text(value,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5))),
      ]),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 22. FLAME BANNER
// ────────────────────────────────────────────────────────────
class _FlameBanner extends StatelessWidget {
  final bool flame;
  const _FlameBanner({required this.flame});

  @override
  Widget build(BuildContext context) {
    final color = flame ? _DT.red : _DT.green;
    return _GCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      glowColor: color,
      dangerBorder: flame,
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: color.withValues(alpha: 0.15),
          ),
          child: Icon(
            flame
                ? Icons.local_fire_department_rounded
                : Icons.shield_rounded,
            color: color,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              flame ? '⚠️ FLAME DETECTED' : 'All Clear',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: -0.2),
            ),
            const SizedBox(height: 2),
            Text(
              flame
                  ? 'Immediate action required'
                  : 'Flame Sensor • No alerts detected',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5)),
            ),
          ],
        )),
        Icon(Icons.chevron_right_rounded,
            size: 18,
            color:
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
      ]),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 23. ROOMS HEADER + TABS (UPDATED WITH DYNAMIC ROOMS)
// ────────────────────────────────────────────────────────────
class _RoomsHeader extends StatelessWidget {
  final String selectedRoom;
  final ValueChanged<String> onRoomSelected;
  final List<String> rooms;

  const _RoomsHeader({
    required this.selectedRoom,
    required this.onRoomSelected,
    required this.rooms,
  });

  String _getRoomEmoji(String roomName) {
    if (roomName.contains('Living')) return '🛋️';
    if (roomName.contains('Bed')) return '🛏️';
    if (roomName.contains('Kitchen')) return '🍳';
    if (roomName.contains('Bath')) return '🚿';
    if (roomName.contains('Office')) return '💼';
    if (roomName.contains('Dining')) return '🍽️';
    if (roomName.contains('Garage')) return '🚗';
    if (roomName.contains('Garden')) return '🌿';
    if (roomName.contains('Study')) return '📚';
    if (roomName.contains('Guest')) return '🚪';
    return '🏠';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (rooms.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Rooms',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              Text('0 Rooms',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _DT.purple)),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.04),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: _DT.purple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No rooms yet. Tap the + button to add a room.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Rooms',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface)),
            Text('${rooms.length} Rooms',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _DT.purple)),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final name = rooms[i];
              final selected = name == selectedRoom;
              final emoji = _getRoomEmoji(name);

              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onRoomSelected(name);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: selected
                        ? (isDark ? _DT.purple : _DT.purple)
                        : (isDark
                        ? Colors.white.withValues(alpha: 0.07)
                        : Colors.black.withValues(alpha: 0.05)),
                    border: Border.all(
                      color: selected
                          ? _DT.purple
                          : Colors.transparent,
                      width: selected ? 1.5 : 0,
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(emoji, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    Text(name,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? Colors.white
                                : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6))),
                  ]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────
// 24. OPTION TILE
// ────────────────────────────────────────────────────────────
class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: iconColor ?? _DT.purple,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(subtitle),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
      ),
      onTap: onTap,
    );
  }
}

// ────────────────────────────────────────────────────────────
// 25. GLASS CARD
// ────────────────────────────────────────────────────────────
class _GCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? glowColor;
  final bool dangerBorder;

  const _GCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.glowColor,
    this.dangerBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                Colors.white.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.03)
              ]
                  : [
                Colors.white.withValues(alpha: 0.6),
                Colors.white.withValues(alpha: 0.3)
              ],
            ),
            border: Border.all(
              color: dangerBorder
                  ? _DT.red.withValues(alpha: 0.45)
                  : (isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.4)),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.05),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
              if (glowColor != null)
                BoxShadow(
                  color: glowColor!.withValues(alpha: isDark ? 0.18 : 0.12),
                  blurRadius: 24,
                ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 26. PILL BUTTON
// ────────────────────────────────────────────────────────────
class _PillBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _PillBtn({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        gradient: const LinearGradient(
          colors: [Color(0xFF8B7FFF), _DT.purple],
        ),
        boxShadow: [
          BoxShadow(
              color: _DT.purple.withValues(alpha: 0.35), blurRadius: 14),
        ],
      ),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600)),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 27. GLASS BOTTOM NAV
// ────────────────────────────────────────────────────────────
class _GlassBottomNav extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _GlassBottomNav({
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  State<_GlassBottomNav> createState() => _GlassBottomNavState();
}

class _GlassBottomNavState extends State<_GlassBottomNav>
    with SingleTickerProviderStateMixin {
  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.bolt_rounded, 'Energy'),
    (Icons.notifications_rounded, 'Alerts'),
    (Icons.settings_rounded, 'Settings'),
  ];

  late AnimationController _pillController;
  late Animation<double> _pillPosition;

  double _visualPosition = 0;
  bool _isDragging = false;
  double _tabWidth = 0;
  int _prevIndex = 0;

  @override
  void initState() {
    super.initState();
    _prevIndex = widget.selectedIndex;
    _visualPosition = widget.selectedIndex.toDouble();
    _pillController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _pillPosition = AlwaysStoppedAnimation(_visualPosition);
  }

  @override
  void didUpdateWidget(_GlassBottomNav old) {
    super.didUpdateWidget(old);
    if (!_isDragging && old.selectedIndex != widget.selectedIndex) {
      _animatePillTo(widget.selectedIndex.toDouble());
      _prevIndex = widget.selectedIndex;
    }
  }

  void _animatePillTo(double target) {
    final from = _visualPosition;
    _pillPosition = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _pillController, curve: Curves.easeOutExpo),
    );
    _pillController.forward(from: 0).then((_) {
      _visualPosition = target;
    });
  }

  double _dxToIndex(double dx) {
    if (_tabWidth <= 0) return widget.selectedIndex.toDouble();
    return (dx / _tabWidth).clamp(0.0, _items.length - 1.0);
  }

  int _nearestTab(double fractional) => fractional.round().clamp(0, _items.length - 1);

  void _onDragStart(DragStartDetails d) {
    _isDragging = true;
    _pillController.stop();
    final idx = _dxToIndex(d.localPosition.dx);
    setState(() {
      _visualPosition = idx;
      _pillPosition = AlwaysStoppedAnimation(idx);
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final idx = _dxToIndex(d.localPosition.dx);
    final nearest = _nearestTab(idx);

    setState(() {
      _visualPosition = idx;
      _pillPosition = AlwaysStoppedAnimation(idx);
    });

    if (nearest != _prevIndex) {
      HapticFeedback.selectionClick();
      _prevIndex = nearest;
      widget.onTap(nearest);
    }
  }

  void _onDragEnd(DragEndDetails d) {
    _isDragging = false;
    final nearest = _nearestTab(_visualPosition);
    _animatePillTo(nearest.toDouble());
    widget.onTap(nearest);
  }

  void _onTap(int index) {
    if (_isDragging) return;
    HapticFeedback.selectionClick();
    _animatePillTo(index.toDouble());
    _prevIndex = index;
    widget.onTap(index);
  }

  @override
  void dispose() {
    _pillController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 68,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(34),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: _DT.purple.withValues(alpha: isDark ? 0.08 : 0.05),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(34),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                  Colors.white.withValues(alpha: 0.13),
                  Colors.white.withValues(alpha: 0.07),
                ]
                    : [
                  Colors.white.withValues(alpha: 0.72),
                  Colors.white.withValues(alpha: 0.48),
                ],
              ),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.6),
                width: 0.8,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                _tabWidth = constraints.maxWidth / _items.length;

                return GestureDetector(
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  behavior: HitTestBehavior.opaque,
                  child: Stack(children: [
                    AnimatedBuilder(
                      animation: _pillPosition,
                      builder: (context, _) {
                        return Positioned(
                          top: 8,
                          bottom: 8,
                          left: _pillPosition.value * _tabWidth + 6,
                          width: _tabWidth - 12,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(26),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                  sigmaX: 12, sigmaY: 12),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(26),
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: isDark
                                        ? [
                                      _DT.purple.withValues(alpha: 0.38),
                                      _DT.purple.withValues(alpha: 0.20),
                                    ]
                                        : [
                                      _DT.purple.withValues(alpha: 0.20),
                                      _DT.purple.withValues(alpha: 0.10),
                                    ],
                                  ),
                                  border: Border.all(
                                    color: _DT.purple.withValues(
                                        alpha: isDark ? 0.50 : 0.30),
                                    width: 0.8,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _DT.purple.withValues(alpha: 0.28),
                                      blurRadius: 14,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),

                    Row(
                      children: _items.asMap().entries.map((entry) {
                        final index = entry.key;
                        final (icon, label) = entry.value;
                        final isActive = widget.selectedIndex == index;

                        return Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _onTap(index),
                            child: SizedBox(
                              height: 68,
                              child: Column(
                                mainAxisAlignment:
                                MainAxisAlignment.center,
                                children: [
                                  AnimatedSwitcher(
                                    duration:
                                    const Duration(milliseconds: 180),
                                    child: Icon(
                                      icon,
                                      key: ValueKey(isActive),
                                      size: isActive ? 24 : 21,
                                      color: isActive
                                          ? _DT.purple
                                          : (isDark
                                          ? Colors.white
                                          .withValues(alpha: 0.38)
                                          : Colors.black
                                          .withValues(alpha: 0.28)),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  AnimatedDefaultTextStyle(
                                    duration:
                                    const Duration(milliseconds: 180),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: isActive
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: isActive
                                          ? _DT.purple
                                          : (isDark
                                          ? Colors.white
                                          .withValues(alpha: 0.38)
                                          : Colors.black
                                          .withValues(alpha: 0.28)),
                                    ),
                                    child: Text(label),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 28. ENERGY SCREEN
// ────────────────────────────────────────────────────────────
class _EnergyScreen extends StatelessWidget {
  const _EnergyScreen();

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
        left: padding,
        right: padding,
        bottom: isDesktop ? 40 : 100,
      ),
      child: Column(children: [
        _GCard(
          glowColor: _DT.purple,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Today's Usage",
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: _DT.purple.withValues(alpha: 0.15),
                      ),
                      child: const Text('⚡ Live',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _DT.purple)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Column(children: [
                        Text('3.4',
                            style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                color: Theme.of(context).colorScheme.primary)),
                        Text('kWh',
                            style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.5))),
                      ]),
                      Container(
                          width: 0.5,
                          height: 50,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.15)),
                      const Column(children: [
                        Text('€2.15',
                            style: TextStyle(
                                fontSize: 30, fontWeight: FontWeight.w800)),
                        Text('Cost',
                            style:
                            TextStyle(fontSize: 13, color: Colors.grey)),
                      ]),
                    ]),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: 0.45,
                    minHeight: 6,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation(
                        Theme.of(context).colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Daily target',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5))),
                    Text('45%',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary)),
                  ],
                ),
              ]),
        ),
        const SizedBox(height: 12),
        _GCard(
            child: Row(children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This Week',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6))),
                  const SizedBox(height: 6),
                  const Text('24.1 kWh',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8)),
                  const SizedBox(height: 4),
                  const Text('↓ 8% vs last week',
                      style: TextStyle(
                          fontSize: 12,
                          color: _DT.green,
                          fontWeight: FontWeight.w500)),
                ],
              )),
              SizedBox(
                width: 72,
                height: 72,
                child: CircularProgressIndicator(
                  value: 0.62,
                  strokeWidth: 7,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation(
                      Theme.of(context).colorScheme.primary),
                  strokeCap: StrokeCap.round,
                ),
              ),
            ])),
        const SizedBox(height: 12),
        _GCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Top Devices',
                    style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                ...[
                  (Icons.ac_unit_rounded, 'Living Room AC', '2.1 kWh', 0.62),
                  (Icons.kitchen_rounded, 'Kitchen Fridge', '1.8 kWh', 0.53),
                  (Icons.water_damage_rounded, 'Water Heater', '1.2 kWh', 0.35),
                ].map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(children: [
                    Row(children: [
                      Icon(d.$1, size: 20, color: _DT.purple),
                      const SizedBox(width: 10),
                      Expanded(child: Text(d.$2,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500))),
                      Text(d.$3,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: d.$4,
                        minHeight: 4,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.08),
                        valueColor: AlwaysStoppedAnimation(
                            Theme.of(context).colorScheme.primary),
                      ),
                    ),
                  ]),
                )),
              ],
            )),
      ]),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 29. ALERTS SCREEN
// ────────────────────────────────────────────────────────────
class _AlertsScreen extends StatelessWidget {
  const _AlertsScreen();

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    final alerts = [
      (Icons.motion_photos_on_rounded, Colors.orange,
      'Motion in Living Room', '2 minutes ago'),
      (Icons.local_fire_department_rounded, _DT.red,
      'Flame sensor test — All Clear', '1 hour ago'),
      (Icons.power_off_rounded, _DT.blue,
      'Device offline: Bedroom Light', '3 hours ago'),
      (Icons.water_drop_rounded, Colors.teal,
      'High humidity in Kitchen', '5 hours ago'),
    ];

    return ListView.separated(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
        left: padding,
        right: padding,
        bottom: isDesktop ? 40 : 100,
      ),
      itemCount: alerts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final (icon, color, title, time) = alerts[i];
        return _GCard(
          padding: const EdgeInsets.all(14),
          glowColor: i == 0 ? color : null,
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: color.withValues(alpha: 0.15),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(time,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.45))),
              ],
            )),
            Icon(Icons.chevron_right_rounded,
                size: 18,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.3)),
          ]),
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────
// 30. SETTINGS SCREEN
// ────────────────────────────────────────────────────────────
class _SettingsScreen extends ConsumerWidget {
  const _SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final bleStatus = ref.watch(bleServiceProvider).currentStatus;
    final esp32CodeAsync = ref.watch(userEsp32CodeProvider);
    final authService = ref.watch(authServiceProvider).requireValue;
    final user = authService.currentUser;

    void onConnectBLE() => ref.read(bleServiceProvider).connect();

    Future<void> onRefresh() async {
      final ble = ref.read(bleServiceProvider);
      await ble.connect();
      ref.invalidate(httpDataProvider);
    }

    void showEditCodeDialog() {
      final rootContext = context;
      final TextEditingController codeController = TextEditingController(
          text: esp32CodeAsync.value ?? ''
      );

      showDialog(
        context: rootContext,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _DT.purple.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.nfc_rounded,
                    color: _DT.purple,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ESP32 Unique Code',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the unique code of your ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(dialogContext).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                    hintText: 'e.g. ESP32-ABCD-1234',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(dialogContext).colorScheme.onSurface.withValues(alpha: 0.1),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _DT.purple, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final newCode = codeController.text.trim();
                          if (newCode.isNotEmpty && user != null) {
                            try {
                              await authService.updateEsp32Code(user.uid, newCode);
                              ref.invalidate(userEsp32CodeProvider);
                              Navigator.pop(dialogContext);
                              if (rootContext.mounted) _showSnack(rootContext, '✅ ESP32 Code updated to $newCode', color: _DT.green);
                            } catch (e) {
                              if (rootContext.mounted) _showSnack(rootContext, '❌ Failed to update Code: ${e.toString()}', color: _DT.red);
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _DT.purple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          'Update Code',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    void showTestConnectionDialog() async {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(color: _DT.purple),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Testing Connection...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please wait while we test the connection to ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      try {
        final esp32Service = await ref.read(esp32DeviceServiceProvider.future);
        final devices = await esp32Service.getDevices();
        Navigator.pop(context);

        final isConnected = devices['devices'] != null;

        showDialog(
          context: context,
          builder: (context) => Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: Colors.transparent,
            child: _GCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (isConnected ? _DT.green : _DT.red).withValues(alpha: 0.15),
                    ),
                    child: Icon(
                      isConnected ? Icons.check_rounded : Icons.close_rounded,
                      color: isConnected ? _DT.green : _DT.red,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isConnected ? '✅ Connected!' : '❌ Connection Failed',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: isConnected ? _DT.green : _DT.red,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isConnected
                        ? 'ESP32 is reachable via code ${esp32CodeAsync.value ?? "Unknown"}'
                        : 'Could not reach ESP32 with code ${esp32CodeAsync.value ?? "Unknown"}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (isConnected) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Found ${(devices['devices'] as List?)?.length ?? 0} devices',
                      style: TextStyle(
                        fontSize: 14,
                        color: _DT.purple,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } catch (e) {
        Navigator.pop(context);
        showDialog(
          context: context,
          builder: (context) => Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: Colors.transparent,
            child: _GCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _DT.red.withValues(alpha: 0.15),
                    ),
                    child: const Icon(
                      Icons.error_rounded,
                      color: _DT.red,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '❌ Connection Error',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: _DT.red,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Error: ${e.toString()}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    void showSignOutDialog() {
      final rootContext = context;
      showDialog(
        context: rootContext,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.transparent,
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _DT.red.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: _DT.red,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Sign Out',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Are you sure you want to sign out?',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          try {
                            await authService.signOut();
                            ref.read(selectedNavIndexProvider.notifier).state = 0;
                            ref.invalidate(userDataProvider);
                            ref.invalidate(userEsp32CodeProvider);
                            ref.invalidate(httpDataProvider);
                            if (rootContext.mounted) {
                              Navigator.of(rootContext, rootNavigator: true)
                                  .pushNamedAndRemoveUntil('/login', (route) => false);
                            }
                          } catch (e) {
                            if (rootContext.mounted) {
                              _showSnack(rootContext, 'Failed to sign out: $e', color: _DT.red);
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _DT.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Sign Out'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return esp32CodeAsync.when(
      data: (esp32Code) {
        return ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
            left: padding,
            right: padding,
            bottom: isDesktop ? 40 : 100,
          ),
          children: [
            _GCard(child: Column(children: [
              _STile(
                icon: Icons.palette_rounded,
                title: 'Appearance',
                subtitle: 'Theme mode',
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<ThemeMode>(
                    value: themeMode,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    borderRadius: BorderRadius.circular(16),
                    items: const [
                      DropdownMenuItem(
                          value: ThemeMode.light, child: Text('Light')),
                      DropdownMenuItem(
                          value: ThemeMode.dark, child: Text('Dark')),
                      DropdownMenuItem(
                          value: ThemeMode.system,
                          child: Text('System')),
                    ],
                    onChanged: (m) {
                      if (m != null) {
                        ref.read(themeModeProvider.notifier).state = m;
                      }
                    },
                  ),
                ),
              ),
              const _SDivider(),
              _STile(
                icon: Icons.bluetooth_rounded,
                title: 'Bluetooth',
                subtitle: bleStatus == BleStatus.connected
                    ? 'Connected'
                    : 'Not connected',
                trailing: bleStatus == BleStatus.connected
                    ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: _DT.green.withValues(alpha: 0.15),
                    border: Border.all(
                        color: _DT.green.withValues(alpha: 0.4),
                        width: 0.8),
                  ),
                  child: const Text('● Connected',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _DT.green)),
                )
                    : _PillBtn(label: 'Connect', onTap: onConnectBLE),
              ),
              const _SDivider(),
              _STile(
                icon: Icons.refresh_rounded,
                title: 'Manual Refresh',
                subtitle: 'Pull from BLE / Cloud',
                trailing: GestureDetector(
                  onTap: onRefresh,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _DT.purple.withValues(alpha: 0.15),
                    ),
                    child: const Icon(Icons.refresh_rounded,
                        size: 20, color: _DT.purple),
                  ),
                ),
              ),
            ])),
            const SizedBox(height: 12),
            _GCard(child: Column(children: [
              _STile(
                icon: Icons.nfc_rounded,
                title: 'ESP32 Settings',
                subtitle: 'Code: ${esp32Code ?? "Not set"}',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: showEditCodeDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: _DT.purple.withValues(alpha: 0.15),
                        ),
                        child: const Text(
                          'Edit Code',
                          style: TextStyle(
                            color: _DT.purple,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: showTestConnectionDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: _DT.green.withValues(alpha: 0.15),
                        ),
                        child: const Text(
                          'Test',
                          style: TextStyle(
                            color: _DT.green,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                onTap: showEditCodeDialog,
              ),
              const _SDivider(),
              _STile(
                icon: Icons.logout_rounded,
                title: 'Sign Out',
                subtitle: 'Sign out of your account',
                onTap: showSignOutDialog,
                trailing: GestureDetector(
                  onTap: showSignOutDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: _DT.red.withValues(alpha: 0.15),
                    ),
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(
                        color: _DT.red,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const _SDivider(),
              _STile(
                icon: Icons.router_rounded,
                title: 'Provision ESP32',
                subtitle: 'Setup a new device',
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35)),
                onTap: () {
                  Navigator.pushNamed(context, '/provision');
                },
              ),
              const _SDivider(),
              _STile(
                icon: Icons.wifi_rounded,
                title: 'Wi-Fi Config',
                subtitle: 'Change network settings',
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35)),
                onTap: () {
                  Navigator.pushNamed(context, '/wifiConfig');
                },
              ),
              const _SDivider(),
              _STile(
                icon: Icons.info_outline_rounded,
                title: 'About',
                subtitle: 'Smart Home v1.0.0',
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35)),
                onTap: () {},
              ),
            ])),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
    );
  }
}

class _SDivider extends StatelessWidget {
  const _SDivider();

  @override
  Widget build(BuildContext context) => Container(
    height: 0.5,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color:
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
  );
}

class _STile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  const _STile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _DT.purple.withValues(alpha: 0.12),
          ),
          child: Icon(icon, color: _DT.purple, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5))),
          ],
        )),
        trailing,
      ]),
    );
    return onTap != null
        ? GestureDetector(onTap: onTap, child: tile)
        : tile;
  }
}

// ────────────────────────────────────────────────────────────
// 31. SKELETON LOADER
// ────────────────────────────────────────────────────────────
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return Shimmer.fromColors(
      baseColor: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.07),
      highlightColor: isDark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.03),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
          left: padding,
          right: padding,
          bottom: isDesktop ? 40 : 100,
        ),
        child: const Column(children: [
          _SBox(h: 54, r: 16),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _SBox(h: 90, r: 20)),
            SizedBox(width: 10),
            Expanded(child: _SBox(h: 90, r: 20)),
            SizedBox(width: 10),
            Expanded(child: _SBox(h: 90, r: 20)),
          ]),
          SizedBox(height: 12),
          _SBox(h: 64, r: 16),
          SizedBox(height: 12),
          _SBox(h: 40, r: 16),
          SizedBox(height: 12),
          Row(children: [
            Expanded(child: _SBox(h: 160, r: 20)),
            SizedBox(width: 12),
            Expanded(child: _SBox(h: 160, r: 20)),
          ]),
          SizedBox(height: 12),
          Row(children: [
            Expanded(child: _SBox(h: 160, r: 20)),
            SizedBox(width: 12),
            Expanded(child: _SBox(h: 160, r: 20)),
          ]),
        ]),
      ),
    );
  }
}

class _SBox extends StatelessWidget {
  final double h;
  final double r;
  const _SBox({required this.h, required this.r});

  @override
  Widget build(BuildContext context) => Container(
    height: h,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(r),
    ),
  );
}
