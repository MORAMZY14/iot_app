import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'ble_service.dart';

// ────────────────────────────────────────────────────────────
// 0. THEME MANAGEMENT
// ────────────────────────────────────────────────────────────
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// Nav index lives in a provider so theme changes don't reset it
final selectedNavIndexProvider = StateProvider<int>((ref) => 0);

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
// 4. ESP32 DEVICE MANAGEMENT SERVICE
// ────────────────────────────────────────────────────────────
class ESP32DeviceService {
  final String esp32Ip;

  ESP32DeviceService(this.esp32Ip);

  Future<Map<String, dynamic>> getDevices() async {
    try {
      final response = await http.get(
        Uri.parse('http://$esp32Ip/api/devices'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'devices': []};
    } catch (e) {
      print('Error getting devices: $e');
      return {'devices': []};
    }
  }

  Future<bool> addDevice({
    required String name,
    required int type,
    required int gpio,
    required String room,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('http://$esp32Ip/api/devices/add'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'name': name,
          'type': type.toString(),
          'gpio': gpio.toString(),
          'room': room,
        },
      ).timeout(const Duration(seconds: 5));

      print('Add device response: ${response.statusCode} - ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      print('Error adding device: $e');
      return false;
    }
  }

  Future<bool> editDeviceGPIO({
    required String id,
    required int newGpio,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('http://$esp32Ip/api/devices/edit-gpio'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'id': id,
          'gpio': newGpio.toString(),
        },
      ).timeout(const Duration(seconds: 5));

      print('Edit GPIO response: ${response.statusCode} - ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      print('Error editing GPIO: $e');
      return false;
    }
  }

  Future<bool> controlDevice({
    required String id,
    required bool state,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('http://$esp32Ip/api/devices/control'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'id': id,
          'state': state.toString(),
        },
      ).timeout(const Duration(seconds: 3));

      return response.statusCode == 200;
    } catch (e) {
      print('Error controlling device: $e');
      return false;
    }
  }

  Future<bool> removeDevice(String id) async {
    try {
      final response = await http.post(
        Uri.parse('http://$esp32Ip/api/devices/remove'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'id': id},
      ).timeout(const Duration(seconds: 3));

      return response.statusCode == 200;
    } catch (e) {
      print('Error removing device: $e');
      return false;
    }
  }

  Future<List<int>> getAvailableGPIOs() async {
    try {
      final response = await http.get(
        Uri.parse('http://$esp32Ip/api/gpio/scan'),
      ).timeout(const Duration(seconds: 3));

      print('GPIO scan response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final available = data['available'] as List? ?? [];
        return available.map((e) => e['pin'] as int).toList();
      }
      return _getDefaultGPIOs();
    } catch (e) {
      print('Error getting GPIOs: $e');
      return _getDefaultGPIOs();
    }
  }

  List<int> _getDefaultGPIOs() {
    return [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
  }

  Future<List<String>> getRooms() async {
    try {
      final response = await http.get(
        Uri.parse('http://$esp32Ip/api/rooms'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['rooms'] as List? ?? []).map((e) => e as String).toList();
      }
      return ['Living Room', 'Bedroom', 'Kitchen', 'Bathroom'];
    } catch (e) {
      return ['Living Room', 'Bedroom', 'Kitchen', 'Bathroom'];
    }
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

// ESP32 IP provider
final esp32IpProvider = StateProvider<String>((ref) => '192.168.1.9');

// ESP32 Device Service Provider
final esp32DeviceServiceProvider = Provider<ESP32DeviceService>((ref) {
  final ip = ref.watch(esp32IpProvider);
  return ESP32DeviceService(ip);
});

// ────────────────────────────────────────────────────────────
// 5. HTTP POLLING SERVICE WITH CACHING
// ────────────────────────────────────────────────────────────
final databaseUrlProvider = Provider((ref) =>
'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app');

final httpDataProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final url = ref.watch(databaseUrlProvider);
  final cache = CacheService();

  final cached = cache.get('smartHome');
  if (cached != null) {
    return cached as Map<String, dynamic>;
  }

  int retryCount = 0;
  final maxRetries = 3;

  while (retryCount < maxRetries) {
    try {
      final response = await http.get(
        Uri.parse('$url/smartHome.json'),
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
            processedData['lights'] = {
              'room1': false,
              'room2': false,
              'room3': false,
            };
          }

          if (!processedData.containsKey('status')) {
            processedData['status'] = {'online': false};
          }

          final status = processedData['status'] as Map? ?? {};
          int lastSeen = status['lastSeen'] as int? ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          status['online'] = (now - lastSeen) < 10 && lastSeen > 0;
          processedData['status'] = status;

          cache.set('smartHome', processedData);
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
    'lights': {'room1': false, 'room2': false, 'room3': false},
    'status': {'online': false},
  };
});

// ────────────────────────────────────────────────────────────
// 6. BLE + HTTP MERGED DATA PROVIDER
// ────────────────────────────────────────────────────────────
final bleServiceProvider = Provider<BleService>((ref) => BleService());

final smartHomeDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final controller = StreamController<Map<String, dynamic>>();
  late StreamSubscription bleStatusSub;
  Timer? httpTimer;
  final cache = CacheService();

  Map<String, dynamic> currentData = {
    'sensors': {'temperature': 0.0, 'humidity': 0.0, 'flame': false},
    'lights': {'room1': false, 'room2': false, 'room3': false},
    'status': {'online': false},
  };

  void updateFromBle() {
    if (bleService.currentStatus == BleStatus.connected) {
      currentData['sensors'] = {
        'temperature': bleService.temperature,
        'humidity': bleService.humidity,
        'flame': bleService.flameDetected,
      };
      currentData['lights'] = Map.from(bleService.lights);
      currentData['status']['online'] = true;
      cache.set('bleData', currentData);
      if (!controller.isClosed) controller.add(currentData);
    }
  }

  Future<void> fetchHttpData() async {
    final httpData = await ref.read(httpDataProvider.future);
    if (bleService.currentStatus != BleStatus.connected) {
      final cachedBle = cache.get('bleData');
      if (cachedBle != null) {
        currentData = Map<String, dynamic>.from(cachedBle as Map);
        currentData['status'] = httpData['status'] ?? currentData['status'];
        if (!controller.isClosed) controller.add(currentData);
        return;
      }
      currentData = httpData;
      if (!controller.isClosed) controller.add(currentData);
    } else if (httpData.containsKey('status')) {
      currentData['status'] = httpData['status'];
      if (!controller.isClosed) controller.add(currentData);
    }
  }

  final cachedData = cache.get('bleData');
  if (cachedData != null) {
    currentData = Map<String, dynamic>.from(cachedData as Map);
    Future.microtask(() {
      if (!controller.isClosed) controller.add(currentData);
    });
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
// 7. LIGHT TOGGLE SERVICE
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

    _patchCache('smartHome', room, value);
    _patchCache('bleData', room, value);

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
        Uri.parse('$url/smartHome/lights.json'),
        body: jsonEncode({room: value}),
      )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      _revertCache('smartHome', room, !value);
      _revertCache('bleData', room, !value);
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
// 8. WALLPAPER BACKGROUND
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
// 9. DASHBOARD PAGE
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
// 10. PASSWORD DIALOG
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
// 11. EDIT GPIO DIALOG
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
      final service = ref.read(esp32DeviceServiceProvider);
      final gpios = await service.getAvailableGPIOs();
      setState(() {
        _availableGPIOs = gpios;
        if (!_availableGPIOs.contains(widget.currentGpio)) {
          _availableGPIOs.add(widget.currentGpio);
          _availableGPIOs.sort();
        }
      });
    } catch (e) {
      _availableGPIOs = [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
      setState(() {});
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
      final service = ref.read(esp32DeviceServiceProvider);
      final success = await service.editDeviceGPIO(
        id: widget.deviceId,
        newGpio: _selectedGpio,
      );

      setState(() => _isLoading = false);

      if (mounted) {
        if (success) {
          Navigator.pop(context, true);
          _showSnack(context, '✅ GPIO updated successfully!', color: _DT.green);
        } else {
          _showSnack(context, '❌ Failed to update GPIO', color: _DT.red);
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
      }
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
                  onChanged: (value) {
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
// 12. QUICK ACTION DIALOG (FIXED)
// ────────────────────────────────────────────────────────────
class _QuickActionDialog extends ConsumerStatefulWidget {
  const _QuickActionDialog();

  @override
  ConsumerState<_QuickActionDialog> createState() => _QuickActionDialogState();
}

class _QuickActionDialogState extends ConsumerState<_QuickActionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _gpioController = TextEditingController();

  int _selectedType = 0;
  String _selectedRoom = 'Living Room';
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
    setState(() => _isLoading = true);

    try {
      final service = ref.read(esp32DeviceServiceProvider);

      List<int> gpios = [];
      List<String> rooms = [];
      List<Map<String, dynamic>> types = [];

      try {
        gpios = await service.getAvailableGPIOs().timeout(const Duration(seconds: 3));
      } catch (e) {
        print('GPIO fetch failed: $e');
        gpios = [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
      }

      try {
        rooms = await service.getRooms().timeout(const Duration(seconds: 3));
      } catch (e) {
        print('Rooms fetch failed: $e');
        rooms = ['Living Room', 'Bedroom', 'Kitchen', 'Bathroom'];
      }

      try {
        types = await service.getDeviceTypes().timeout(const Duration(seconds: 3));
      } catch (e) {
        print('Types fetch failed: $e');
        types = [
          {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
          {'type': 1, 'name': 'Fan', 'icon': 'fan'},
          {'type': 2, 'name': 'Switch', 'icon': 'power'},
          {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
        ];
      }

      setState(() {
        _availableGPIOs = gpios;
        _rooms = rooms;
        _deviceTypes = types;
        _isLoading = false;
      });

      if (gpios.isEmpty && mounted) {
        _showSnack(context, '⚠️ Using default GPIOs (ESP32 not responding)', color: Colors.orange);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _availableGPIOs = [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
        _rooms = ['Living Room', 'Bedroom', 'Kitchen', 'Bathroom'];
        _deviceTypes = [
          {'type': 0, 'name': 'Light', 'icon': 'lightbulb'},
          {'type': 1, 'name': 'Fan', 'icon': 'fan'},
          {'type': 2, 'name': 'Switch', 'icon': 'power'},
          {'type': 3, 'name': 'Socket', 'icon': 'power_plug'},
        ];
      });
      if (mounted) {
        _showSnack(context, '⚠️ ESP32 not responding, using defaults', color: Colors.orange);
      }
    }
  }

  Future<void> _addDevice() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final service = ref.read(esp32DeviceServiceProvider);
      final success = await service.addDevice(
        name: _nameController.text.trim(),
        type: _selectedType,
        gpio: int.parse(_gpioController.text.trim()),
        room: _selectedRoom,
      );

      setState(() => _isLoading = false);

      if (success) {
        if (mounted) {
          Navigator.pop(context);
          _showSnack(context, '✅ Device added successfully!', color: _DT.green);
        }
      } else {
        if (mounted) {
          _showSnack(context, '❌ Failed to add device', color: _DT.red);
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: _GCard(
        padding: const EdgeInsets.all(24),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Add New Device',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
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
            const SizedBox(height: 4),
            Text(
              'Connect a new device to your ESP32',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _isLoading && _rooms.isEmpty
                  ? const Center(
                child: CircularProgressIndicator(color: _DT.purple),
              )
                  : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                        decoration: InputDecoration(
                          hintText: 'e.g. Living Room Lamp',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: _DT.purple, width: 2),
                          ),
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
                              onTap: () => setState(() => _selectedType = type['type'] as int),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  color: isSelected ? _DT.purple : Colors.transparent,
                                  border: Border.all(
                                    color: isSelected ? _DT.purple : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
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
                                        color: isSelected ? Colors.white : Theme.of(context).colorScheme.onSurface,
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
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'GPIO Pin',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextFormField(
                                  controller: _gpioController,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    hintText: 'e.g. 14',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: _DT.purple, width: 2),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'Required';
                                    }
                                    final pin = int.tryParse(value.trim());
                                    if (pin == null) {
                                      return 'Invalid number';
                                    }
                                    if (!_availableGPIOs.contains(pin)) {
                                      return 'GPIO ${pin} not available';
                                    }
                                    return null;
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
                                      value: _selectedRoom,
                                      isExpanded: true,
                                      items: _rooms.map((room) {
                                        return DropdownMenuItem(
                                          value: room,
                                          child: Text(room),
                                        );
                                      }).toList(),
                                      onChanged: (value) {
                                        if (value != null) {
                                          setState(() => _selectedRoom = value);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: _DT.purple.withValues(alpha: 0.08),
                          border: Border.all(
                            color: _DT.purple.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, color: _DT.purple, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Available GPIOs: ${_availableGPIOs.join(", ")}',
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
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                              : const Text(
                            'Add Device',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
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
    );
  }

  IconData _getIconForType(int type) {
    switch (type) {
      case 0: return Icons.lightbulb_rounded;
      case 1: return Icons.air_rounded;
      case 2: return Icons.power_settings_new_rounded;
      case 3: return Icons.electrical_services_rounded;
      default: return Icons.devices_rounded;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _gpioController.dispose();
    super.dispose();
  }
}

// ────────────────────────────────────────────────────────────
// 13. PURPLE FAB
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
// 14. GLASS APP BAR
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
// 15. HOME CONTENT WRAPPER
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
    return _HomeContent(
      dataAsync: dataAsync,
      onRefresh: _refresh,
      bleStatus: bleService.currentStatus,
      onConnectBLE: () => bleService.connect(),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 16. HOME CONTENT - DYNAMIC DEVICES FROM ESP32 (FIXED)
// ────────────────────────────────────────────────────────────
class _HomeContent extends ConsumerStatefulWidget {
  final AsyncValue<Map<String, dynamic>> dataAsync;
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _HomeContent({
    required this.dataAsync,
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  @override
  ConsumerState<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends ConsumerState<_HomeContent> {
  String _selectedRoom = 'Living Room';
  Map<String, dynamic> _esp32Devices = {};
  bool _isLoadingDevices = false;

  @override
  void initState() {
    super.initState();
    _loadESP32Devices();
  }

  Future<void> _loadESP32Devices() async {
    setState(() => _isLoadingDevices = true);
    try {
      final service = ref.read(esp32DeviceServiceProvider);
      final result = await service.getDevices();
      setState(() {
        _esp32Devices = result;
        _isLoadingDevices = false;
      });
    } catch (e) {
      print('Error loading ESP32 devices: $e');
      setState(() => _isLoadingDevices = false);
    }
  }

  Future<void> _refreshDevices() async {
    await _loadESP32Devices();
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
              child: const Icon(
                Icons.devices_rounded,
                color: _DT.purple,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              deviceName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
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
                );
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
                child: const Icon(
                  Icons.warning_rounded,
                  color: _DT.red,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Remove Device',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
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
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        try {
                          final service = ref.read(esp32DeviceServiceProvider);
                          final success = await service.removeDevice(deviceId);
                          if (success) {
                            _showSnack(context, '✅ Device removed', color: _DT.green);
                            await _loadESP32Devices();
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
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

  // FIXED: Optimistic toggle without full page refresh
  Future<void> _controlDevice(String id, bool state) async {
    try {
      final service = ref.read(esp32DeviceServiceProvider);

      // Optimistically update UI
      setState(() {
        final devices = _esp32Devices['devices'] as List? ?? [];
        final index = devices.indexWhere((d) => d['id'] == id);
        if (index != -1) {
          devices[index]['state'] = state;
          _esp32Devices['devices'] = devices;
        }
      });

      final success = await service.controlDevice(id: id, state: state);

      if (success) {
        _showSnack(context, state ? '✅ Device turned ON' : '✅ Device turned OFF', color: _DT.green);
      } else {
        // Revert on failure
        setState(() {
          final devices = _esp32Devices['devices'] as List? ?? [];
          final index = devices.indexWhere((d) => d['id'] == id);
          if (index != -1) {
            devices[index]['state'] = !state;
            _esp32Devices['devices'] = devices;
          }
        });
        _showSnack(context, '❌ Failed to control device', color: _DT.red);
      }
    } catch (e) {
      // Revert on error
      setState(() {
        final devices = _esp32Devices['devices'] as List? ?? [];
        final index = devices.indexWhere((d) => d['id'] == id);
        if (index != -1) {
          devices[index]['state'] = !state;
          _esp32Devices['devices'] = devices;
        }
      });
      _showSnack(context, '❌ Error: ${e.toString()}', color: _DT.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return RefreshIndicator(
      onRefresh: _refreshDevices,
      displacement: 100,
      color: _DT.purple,
      child: widget.dataAsync.when(
        data: (data) {
          final lights = (data['lights'] as Map?) ?? {};
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

          // Get devices from ESP32
          final devicesList = _esp32Devices['devices'] as List? ?? [];

          // Filter devices by selected room
          final roomDevices = devicesList.where((d) =>
          d['room'] == _selectedRoom || _selectedRoom == 'All Rooms'
          ).toList();

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
                _EspBar(online: online, ip: ip, ping: ping, rssi: rssi),
                const SizedBox(height: 14),
                _StatsRow(temp: temp, hum: hum, todayKw: todayKw),
                const SizedBox(height: 18),
                _FlameBanner(flame: flame),
                const SizedBox(height: 18),
                _RoomsHeader(
                  selectedRoom: _selectedRoom,
                  onRoomSelected: (r) => setState(() => _selectedRoom = r),
                ),
                const SizedBox(height: 14),

                // Dynamic Device Grid
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
                          Icons.devices_rounded,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No devices in this room',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tap the + button to add a device',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _DynamicDeviceGrid(
                    devices: roomDevices,
                    onDeviceTap: (device) {
                      // Toggle device state
                      final id = device['id'] as String;
                      final currentState = device['state'] as bool? ?? false;
                      _controlDevice(id, !currentState);
                    },
                    onLongPress: (device) {
                      _showDeviceOptions(
                        device['id'] as String,
                        device['name'] as String,
                        device['gpio'] as int,
                      );
                    },
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
                const Icon(Icons.error_outline_rounded,
                    size: 48, color: _DT.red),
                const SizedBox(height: 16),
                Text('Something went wrong',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(err.toString(),
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.5)),
                    textAlign: TextAlign.center),
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
// 16.1 DYNAMIC DEVICE GRID
// ────────────────────────────────────────────────────────────
class _DynamicDeviceGrid extends StatelessWidget {
  final List devices;
  final Function(Map<String, dynamic>) onDeviceTap;
  final Function(Map<String, dynamic>) onLongPress;

  const _DynamicDeviceGrid({
    required this.devices,
    required this.onDeviceTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isDesktop = ResponsiveHelper.isDesktop(context);
    final columns = isDesktop ? 4 : 2;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.9,
      ),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        final name = device['name'] as String? ?? 'Unknown';
        final type = device['type'] as int? ?? 0;
        final state = device['state'] as bool? ?? false;
        final gpio = device['gpio'] as int? ?? 0;
        final room = device['room'] as String? ?? '';

        return GestureDetector(
          onTap: () => onDeviceTap(device),
          onLongPress: () => onLongPress(device),
          child: _DynamicDeviceCard(
            name: name,
            type: type,
            state: state,
            gpio: gpio,
            room: room,
          ),
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────
// 16.2 DYNAMIC DEVICE CARD
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
// 17. ESP CONNECTION BAR
// ────────────────────────────────────────────────────────────
class _EspBar extends StatelessWidget {
  final bool online;
  final String ip;
  final int ping;
  final int rssi;

  const _EspBar({
    required this.online,
    required this.ip,
    required this.ping,
    required this.rssi,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = online ? _DT.espConnected : _DT.red;

    return _GCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
            boxShadow: [
              BoxShadow(color: dotColor.withValues(alpha: 0.5), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          online ? 'ESP32 Connected' : 'Disconnected',
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: dotColor),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _MiniChip(label: ip, icon: Icons.settings_ethernet_rounded),
              const SizedBox(width: 5),
              _MiniChip(label: '${ping}ms', icon: Icons.timer_outlined),
              const SizedBox(width: 5),
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
            ]),
          ),
        ),
        Icon(Icons.chevron_right_rounded,
            size: 18,
            color:
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
      ]),
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
// 18. STATS ROW
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
// 19. FLAME BANNER
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
// 20. ROOMS HEADER + TABS
// ────────────────────────────────────────────────────────────
class _RoomsHeader extends StatelessWidget {
  final String selectedRoom;
  final ValueChanged<String> onRoomSelected;

  const _RoomsHeader({
    required this.selectedRoom,
    required this.onRoomSelected,
  });

  static const _rooms = [
    ('🛋️', 'Living Room'),
    ('🛏️', 'Bedroom'),
    ('🍳', 'Kitchen'),
    ('🚿', 'Bathroom'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Rooms',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
          const Text('4 Rooms',
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
          itemCount: _rooms.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final (emoji, name) = _rooms[i];
            final selected = name == selectedRoom;
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
                      ? Colors.white
                      : (Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.07)
                      : Colors.black.withValues(alpha: 0.05)),
                  border: Border.all(
                    color:
                    selected ? Colors.white : Colors.transparent,
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
                              ? Colors.black
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
    ]);
  }
}

// ────────────────────────────────────────────────────────────
// 21. OPTION TILE
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
// 22. GLASS CARD
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
// 23. PILL BUTTON
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
// 24. GLASS BOTTOM NAV
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
// 25. ENERGY SCREEN
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
// 26. ALERTS SCREEN
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
// 27. SETTINGS SCREEN
// ────────────────────────────────────────────────────────────
class _SettingsScreen extends ConsumerWidget {
  const _SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final bleStatus = ref.watch(bleServiceProvider).currentStatus;
    final esp32Ip = ref.watch(esp32IpProvider);
    final esp32Service = ref.watch(esp32DeviceServiceProvider);

    void onConnectBLE() => ref.read(bleServiceProvider).connect();

    Future<void> onRefresh() async {
      final ble = ref.read(bleServiceProvider);
      await ble.connect();
      ref.invalidate(httpDataProvider);
    }

    void showEditIPDialog() {
      final TextEditingController ipController = TextEditingController(text: esp32Ip);

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
                    color: _DT.purple.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.wifi_rounded,
                    color: _DT.purple,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ESP32 IP Address',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the IP address of your ESP32',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: ipController,
                  decoration: InputDecoration(
                    hintText: 'e.g. 192.168.1.100',
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final newIp = ipController.text.trim();
                          if (newIp.isNotEmpty) {
                            ref.read(esp32IpProvider.notifier).state = newIp;
                            Navigator.pop(context);
                            _showSnack(context, '✅ ESP32 IP updated to $newIp', color: _DT.green);
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
                          'Update',
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
                        ? 'ESP32 is reachable at $esp32Ip'
                        : 'Could not reach ESP32 at $esp32Ip',
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

    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

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
            icon: Icons.settings_ethernet_rounded,
            title: 'ESP32 Settings',
            subtitle: 'IP: $esp32Ip',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: showEditIPDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: _DT.purple.withValues(alpha: 0.15),
                    ),
                    child: const Text(
                      'Edit IP',
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
            onTap: showEditIPDialog,
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
            onTap: () {},
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
            onTap: () {},
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
// 28. SKELETON LOADER
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