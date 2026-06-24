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
// 4. HTTP POLLING SERVICE WITH CACHING
// ────────────────────────────────────────────────────────────
final databaseUrlProvider = Provider((ref) =>
'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app');

// FIXED: Using .future instead of .stream
final httpDataProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final url = ref.watch(databaseUrlProvider);
  final cache = CacheService();

  // Check cache first
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
          final status = jsonData['status'] as Map? ?? {};
          int lastSeen = status['lastSeen'] as int? ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          status['online'] = (now - lastSeen) < 10 && lastSeen > 0;
          jsonData['status'] = status;
          cache.set('smartHome', jsonData);
          return jsonData;
        }
      }
    } catch (_) {
      retryCount++;
      if (retryCount < maxRetries) {
        await Future.delayed(Duration(milliseconds: 500 * retryCount));
      }
    }
  }
  return {};
});

// ────────────────────────────────────────────────────────────
// 5. BLE + HTTP MERGED DATA PROVIDER
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

  // Initial fetch
  fetchHttpData();

  // Periodic fetch
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
// 6. LIGHT TOGGLE SERVICE — FIXED: optimistic cache patch
// ────────────────────────────────────────────────────────────
final lightToggleProvider = Provider((ref) => LightToggleService(ref));

class LightToggleService {
  final Ref _ref;
  LightToggleService(this._ref);

  /// Patches the in-memory cache instantly so the stream reflects
  /// the new value without waiting for a network round-trip.
  void _patchCache(String cacheKey, String room, bool value) {
    final cached = CacheService().get(cacheKey);
    if (cached == null) return;
    final updated = Map<String, dynamic>.from(cached as Map);
    final lights = Map<String, dynamic>.from(updated['lights'] ?? {});
    lights[room] = value;
    updated['lights'] = lights;
    CacheService().set(cacheKey, updated);
  }

  /// Reverts the cache patch if the network call fails.
  void _revertCache(String cacheKey, String room, bool originalValue) {
    _patchCache(cacheKey, room, originalValue);
  }

  Future<void> toggle(String room, bool value, BuildContext context) async {
    final bleService = _ref.read(bleServiceProvider);
    final url = _ref.read(databaseUrlProvider);

    // ── 1. Optimistic update in cache (instant UI) ──────────
    _patchCache('smartHome', room, value);
    _patchCache('bleData', room, value);

    // ── 2. Try BLE first ────────────────────────────────────
    if (bleService.currentStatus == BleStatus.connected) {
      try {
        await bleService.setLightState(room, value);
        return; // success — cache already patched, done
      } catch (e) {
        if (context.mounted) {
          _showSnack(context, 'BLE error, trying Wi-Fi…',
              color: Colors.orange);
        }
        // fall through to HTTP
      }
    }

    // ── 3. HTTP fallback ─────────────────────────────────────
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
      // No cache invalidation needed — cache is already up-to-date.
      // The next poll will confirm the server state naturally.
    } catch (e) {
      // ── 4. Revert optimistic update on failure ───────────
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
// 7. WALLPAPER BACKGROUND
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
// 8. DASHBOARD PAGE
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
        _showSnack(context, 'Quick actions coming soon',
            color: _DT.purple);
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
// 9. PURPLE FAB
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
// 10. GLASS APP BAR
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
            leading: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: const CircleAvatar(
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
                const Text(
                  'Good Morning ☀️', // This will be updated dynamically
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      height: 1.2),
                ),
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
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: _DT.red),
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

  String _greeting() {
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
// 11. HOME CONTENT WRAPPER
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
// 12. HOME CONTENT
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
  bool _tvOn = false;
  bool _purifierOn = false;
  bool _soundbarOn = true;
  double _ceilingBrightness = 0.8;
  bool _bathroomLightOn = false;

  // FIXED: local optimistic light state — updated instantly on tap,
  // never waits for network before reflecting in UI.
  final Map<String, bool> _lightStates = {};

  // FIXED: tracks which rooms are currently mid-toggle so
  // we can show a subtle spinner without blocking interaction.
  final Set<String> _togglingKeys = {};

  // Timestamp of the last toggle per key — stream is blocked from
  // overwriting local state for _cooldown after each tap, preventing
  // the on→off→on flicker caused by a poll racing the HTTP PATCH.
  final Map<String, DateTime> _lastToggled = {};
  static const _cooldown = Duration(seconds: 8);

  String? _lightKeyForRoom(String room) {
    switch (room) {
      case 'Living Room': return 'room1';
      case 'Bedroom':     return 'room2';
      case 'Kitchen':     return 'room3';
      default:            return null;
    }
  }

  bool _getLightState(String? key) {
    if (key == null) return false;
    return _lightStates[key] ?? false;
  }

  // FIXED: optimistic toggle — flips state immediately, fires network
  // in background, reverts only if the call fails.
  Future<void> _toggleRoomLight(String room) async {
    final key = _lightKeyForRoom(room);
    if (key == null) return;
    if (_togglingKeys.contains(key)) return; // debounce rapid taps

    final previousValue = _lightStates[key] ?? false;
    final newValue = !previousValue;

    // ── Instant UI update ──────────────────────────────────
    setState(() {
      _lightStates[key] = newValue;
      _togglingKeys.add(key);
      _lastToggled[key] = DateTime.now(); // stamp time so cooldown kicks in
    });

    HapticFeedback.lightImpact();

    try {
      await ref.read(lightToggleProvider).toggle(key, newValue, context);
    } catch (_) {
      // Revert UI and clear cooldown so server can win after a failure
      if (mounted) {
        setState(() {
          _lightStates[key] = previousValue;
          _lastToggled.remove(key);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _togglingKeys.remove(key));
      }
    }
  }

  int _activeCount() {
    if (_selectedRoom == 'Living Room') {
      int count = _getLightState('room1') ? 1 : 0;
      if (_tvOn) count++;
      if (_purifierOn) count++;
      if (_soundbarOn) count++;
      return count;
    }
    final key = _lightKeyForRoom(_selectedRoom);
    return _getLightState(key) ? 1 : 0;
  }

  void _toggleMainLight() {
    if (_selectedRoom == 'Bathroom') {
      setState(() => _bathroomLightOn = !_bathroomLightOn);
      HapticFeedback.lightImpact();
      _showSnack(context, 'Bathroom light toggled (local)');
    } else {
      _toggleRoomLight(_selectedRoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final padding = ResponsiveHelper.getPadding(context);
    final isDesktop = ResponsiveHelper.isDesktop(context);

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      displacement: 100,
      color: _DT.purple,
      child: widget.dataAsync.when(
        data: (data) {
          // FIXED: Only sync from server if we have no local optimistic state.
          // This prevents the stream from overwriting the instant UI update.
          final lights = (data['lights'] as Map?) ?? {};
          final serverStates = Map<String, bool>.from(
              lights.map((k, v) => MapEntry(k, v == true)));

          // Merge: keep local state for keys currently toggling OR within
          // the cooldown window — prevents a poll racing the HTTP PATCH
          // from flickering the toggle back to the old server value.
          for (final entry in serverStates.entries) {
            final lastToggle = _lastToggled[entry.key];
            final isCoolingDown = lastToggle != null &&
                DateTime.now().difference(lastToggle) < _cooldown;

            if (!_togglingKeys.contains(entry.key) && !isCoolingDown) {
              _lightStates[entry.key] = entry.value;
            }
          }

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

          final bool lightOn = _selectedRoom == 'Bathroom'
              ? _bathroomLightOn
              : _getLightState(_lightKeyForRoom(_selectedRoom));

          final currentKey = _lightKeyForRoom(_selectedRoom);
          final isCurrentToggling = currentKey != null &&
              _togglingKeys.contains(currentKey);

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
                _DeviceGrid(
                  selectedRoom: _selectedRoom,
                  lightOn: lightOn,
                  onLightToggle: _toggleMainLight,
                  ceilingBrightness: _ceilingBrightness,
                  onBrightnessChanged: (v) =>
                      setState(() => _ceilingBrightness = v),
                  tvOn: _tvOn,
                  onTvToggle: () => setState(() => _tvOn = !_tvOn),
                  purifierOn: _purifierOn,
                  onPurifierToggle: () =>
                      setState(() => _purifierOn = !_purifierOn),
                  soundbarOn: _soundbarOn,
                  onSoundbarToggle: () =>
                      setState(() => _soundbarOn = !_soundbarOn),
                  activeCount: _activeCount(),
                  // FIXED: pass per-key toggling state instead of global bool
                  isToggling: isCurrentToggling,
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
                _PillBtn(label: 'Try Again', onTap: widget.onRefresh),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 13. ESP CONNECTION BAR
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
// 14. STATS ROW
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
// 15. FLAME BANNER
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
// 16. ROOMS HEADER + TABS
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
// 17. DEVICE GRID
// ────────────────────────────────────────────────────────────
class _DeviceGrid extends StatelessWidget {
  final String selectedRoom;
  final bool lightOn;
  final VoidCallback onLightToggle;
  final double ceilingBrightness;
  final ValueChanged<double> onBrightnessChanged;
  final bool tvOn;
  final VoidCallback onTvToggle;
  final bool purifierOn;
  final VoidCallback onPurifierToggle;
  final bool soundbarOn;
  final VoidCallback onSoundbarToggle;
  final int activeCount;
  final bool isToggling;

  const _DeviceGrid({
    required this.selectedRoom,
    required this.lightOn,
    required this.onLightToggle,
    required this.ceilingBrightness,
    required this.onBrightnessChanged,
    required this.tvOn,
    required this.onTvToggle,
    required this.purifierOn,
    required this.onPurifierToggle,
    required this.soundbarOn,
    required this.onSoundbarToggle,
    required this.activeCount,
    this.isToggling = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDesktop = ResponsiveHelper.isDesktop(context);

    if (selectedRoom != 'Living Room') {
      return _GCard(
        child: _DeviceRow(
          icon: Icons.lightbulb_rounded,
          iconColor: lightOn ? _DT.amber : Colors.grey,
          name: 'Main Light',
          status: lightOn ? 'On' : 'Off',
          isOn: lightOn,
          onToggle: onLightToggle,
          isToggling: isToggling,
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(selectedRoom,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4)),
        const Spacer(),
        // FIXED: spinner only shows while toggling, not blocking interaction
        if (isToggling)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: _DT.purple),
          ),
        const SizedBox(width: 8),
        Text('$activeCount Active',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _DT.purple)),
      ]),
      const SizedBox(height: 14),
      if (isDesktop) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _DeviceCardTall(
            icon: Icons.lightbulb_rounded,
            iconColor: lightOn ? _DT.amber : Colors.grey,
            name: 'Ceiling Light',
            status: lightOn ? 'On • ${(ceilingBrightness * 100).round()}%' : 'Off',
            isOn: lightOn,
            onToggle: onLightToggle,
            accentColor: _DT.amber,
            sliderValue: ceilingBrightness,
            onSliderChanged: onBrightnessChanged,
            isToggling: isToggling,
          )),
          const SizedBox(width: 12),
          Expanded(child: _DeviceCardTall(
            icon: Icons.tv_rounded,
            iconColor: tvOn ? _DT.blue : Colors.grey,
            name: 'Smart TV',
            status: tvOn ? 'On' : 'Off',
            isOn: tvOn,
            onToggle: onTvToggle,
            accentColor: _DT.blue,
            isToggling: false,
          )),
          const SizedBox(width: 12),
          Expanded(child: _DeviceCardTall(
            icon: Icons.air_rounded,
            iconColor: purifierOn ? const Color(0xFF81C784) : Colors.grey,
            name: 'Air Purifier',
            status: purifierOn ? 'On' : 'Off',
            isOn: purifierOn,
            onToggle: onPurifierToggle,
            accentColor: const Color(0xFF81C784),
            isToggling: false,
          )),
          const SizedBox(width: 12),
          Expanded(child: _DeviceCardTall(
            icon: Icons.speaker_rounded,
            iconColor: soundbarOn ? const Color(0xFFCE93D8) : Colors.grey,
            name: 'Soundbar',
            status: soundbarOn ? 'Playing' : 'Paused',
            isOn: soundbarOn,
            onToggle: onSoundbarToggle,
            accentColor: const Color(0xFFCE93D8),
            isToggling: false,
          )),
        ]),
      ] else ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _DeviceCardTall(
            icon: Icons.lightbulb_rounded,
            iconColor: lightOn ? _DT.amber : Colors.grey,
            name: 'Ceiling Light',
            status: lightOn ? 'On • ${(ceilingBrightness * 100).round()}%' : 'Off',
            isOn: lightOn,
            onToggle: onLightToggle,
            accentColor: _DT.amber,
            sliderValue: ceilingBrightness,
            onSliderChanged: onBrightnessChanged,
            isToggling: isToggling,
          )),
          const SizedBox(width: 12),
          Expanded(child: _DeviceCardTall(
            icon: Icons.tv_rounded,
            iconColor: tvOn ? _DT.blue : Colors.grey,
            name: 'Smart TV',
            status: tvOn ? 'On' : 'Off',
            isOn: tvOn,
            onToggle: onTvToggle,
            accentColor: _DT.blue,
            isToggling: false,
          )),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _DeviceCardTall(
            icon: Icons.air_rounded,
            iconColor: purifierOn ? const Color(0xFF81C784) : Colors.grey,
            name: 'Air Purifier',
            status: purifierOn ? 'On' : 'Off',
            isOn: purifierOn,
            onToggle: onPurifierToggle,
            accentColor: const Color(0xFF81C784),
            isToggling: false,
          )),
          const SizedBox(width: 12),
          Expanded(child: _DeviceCardTall(
            icon: Icons.speaker_rounded,
            iconColor: soundbarOn ? const Color(0xFFCE93D8) : Colors.grey,
            name: 'Soundbar',
            status: soundbarOn ? 'Playing' : 'Paused',
            isOn: soundbarOn,
            onToggle: onSoundbarToggle,
            accentColor: const Color(0xFFCE93D8),
            isToggling: false,
          )),
        ]),
      ],
    ]);
  }
}

class _DeviceCardTall extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String name;
  final String status;
  final bool isOn;
  final VoidCallback onToggle;
  final Color accentColor;
  final double? sliderValue;
  final ValueChanged<double>? onSliderChanged;
  final bool isToggling;

  const _DeviceCardTall({
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.status,
    required this.isOn,
    required this.onToggle,
    required this.accentColor,
    this.sliderValue,
    this.onSliderChanged,
    this.isToggling = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RepaintBoundary(
      child: GestureDetector(
        // FIXED: card tap is never blocked — isToggling only drives the spinner
        onTap: onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: isOn
                ? (isDark
                ? accentColor.withValues(alpha: 0.12)
                : accentColor.withValues(alpha: 0.08))
                : (isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.04)),
            border: Border.all(
              color: isOn
                  ? accentColor.withValues(alpha: 0.35)
                  : (isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.07)),
              width: 1,
            ),
            boxShadow: isOn
                ? [
              BoxShadow(
                  color: accentColor.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 4))
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
                        color: iconColor.withValues(alpha: 0.18),
                      ),
                      // FIXED: spinner is decorative — it never blocks tap
                      child: isToggling
                          ? Padding(
                        padding: const EdgeInsets.all(9),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accentColor,
                        ),
                      )
                          : Icon(icon, color: iconColor, size: 20),
                    ),
                    _SmallToggle(
                      value: isOn,
                      onToggle: onToggle,
                      accent: accentColor,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(name,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2)),
                const SizedBox(height: 3),
                Text(status,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: isOn ? accentColor : Colors.grey)),
                if (sliderValue != null && onSliderChanged != null) ...[
                  const SizedBox(height: 10),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: accentColor,
                      inactiveTrackColor: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.12),
                      thumbColor: Colors.white,
                      overlayColor: accentColor.withValues(alpha: 0.12),
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7, elevation: 2),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: sliderValue!,
                      onChanged: onSliderChanged,
                      min: 0,
                      max: 1,
                    ),
                  ),
                  Text('${(sliderValue! * 100).round()}%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: accentColor)),
                ],
              ]),
        ),
      ),
    );
  }
}

class _SmallToggle extends StatelessWidget {
  final bool value;
  final VoidCallback onToggle;
  final Color accent;

  const _SmallToggle({
    required this.value,
    required this.onToggle,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onToggle();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 40,
        height: 24,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: value
              ? accent.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.1),
          border: Border.all(
            color: value
                ? accent.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.15),
            width: 0.8,
          ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? accent : Colors.white.withValues(alpha: 0.5),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 3,
                    offset: const Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String name;
  final String status;
  final bool isOn;
  final VoidCallback onToggle;
  final bool isToggling;

  const _DeviceRow({
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.status,
    required this.isOn,
    required this.onToggle,
    this.isToggling = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: iconColor.withValues(alpha: 0.15),
        ),
        // FIXED: spinner in icon slot, tap never blocked
        child: isToggling
            ? Padding(
          padding: const EdgeInsets.all(10),
          child: CircularProgressIndicator(
              strokeWidth: 2, color: iconColor),
        )
            : Icon(icon, color: iconColor, size: 22),
      ),
      const SizedBox(width: 14),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600)),
          Text(status,
              style: TextStyle(
                  fontSize: 12,
                  color: isOn ? iconColor : Colors.grey)),
        ],
      )),
      _SmallToggle(
        value: isOn,
        onToggle: onToggle,
        accent: iconColor,
      ),
    ]);
  }
}

// ────────────────────────────────────────────────────────────
// 18. GLASS CARD
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
// 19. PILL BUTTON
// ────────────────────────────────────────────────────────────
class _PillBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PillBtn({required this.label, required this.onTap});

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
// 20. GLASS BOTTOM NAV
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
// 21. ENERGY SCREEN
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
// 22. ALERTS SCREEN
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
// 23. SETTINGS SCREEN
// ────────────────────────────────────────────────────────────
class _SettingsScreen extends ConsumerWidget {
  const _SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final bleStatus = ref.watch(bleServiceProvider).currentStatus;
    final onConnectBLE = () => ref.read(bleServiceProvider).connect();
    final onRefresh = () async {
      final ble = ref.read(bleServiceProvider);
      await ble.connect();
      ref.invalidate(httpDataProvider);
    };

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
          _SDivider(),
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
          _SDivider(),
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
          _SDivider(),
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
          _SDivider(),
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
// 24. SKELETON LOADER
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
        child: Column(children: [
          const _SBox(h: 54, r: 16),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: const _SBox(h: 90, r: 20)),
            const SizedBox(width: 10),
            Expanded(child: const _SBox(h: 90, r: 20)),
            const SizedBox(width: 10),
            Expanded(child: const _SBox(h: 90, r: 20)),
          ]),
          const SizedBox(height: 12),
          const _SBox(h: 64, r: 16),
          const SizedBox(height: 12),
          const _SBox(h: 40, r: 16),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: const _SBox(h: 160, r: 20)),
            const SizedBox(width: 12),
            Expanded(child: const _SBox(h: 160, r: 20)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: const _SBox(h: 160, r: 20)),
            const SizedBox(width: 12),
            Expanded(child: const _SBox(h: 160, r: 20)),
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