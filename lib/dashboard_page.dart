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
// 0. THEME MANAGEMENT – FIXED & SIMPLIFIED
// ────────────────────────────────────────────────────────────
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// Light theme – soft warm white with iOS‑27 accents
final lightTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorSchemeSeed: const Color(0xFF007AFF), // iOS blue
  scaffoldBackgroundColor: const Color(0xFFE8EAF6),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  dividerTheme: const DividerThemeData(color: Color(0x22000000)),
);

// Dark theme – deep navy with vibrant accents
final darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorSchemeSeed: const Color(0xFF0A84FF), // iOS dark blue
  scaffoldBackgroundColor: const Color(0xFF080C18),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  dividerTheme: const DividerThemeData(color: Color(0x22FFFFFF)),
);

// ────────────────────────────────────────────────────────────
// 1. HTTP POLLING SERVICE (unchanged)
// ────────────────────────────────────────────────────────────
final databaseUrlProvider = Provider((ref) =>
'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app');

final httpDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final url = ref.watch(databaseUrlProvider);
  final controller = StreamController<Map<String, dynamic>>();

  Timer? timer;
  bool isFetching = false;

  Future<void> fetchData() async {
    if (isFetching) return;
    isFetching = true;
    try {
      final response = await http.get(Uri.parse('$url/smartHome.json'));
      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);
        if (jsonData != null) {
          final status = jsonData['status'] as Map? ?? {};
          int lastSeen = status['lastSeen'] as int? ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          bool isActuallyOnline = (now - lastSeen) < 10 && lastSeen > 0;
          status['online'] = isActuallyOnline;
          jsonData['status'] = status;
          controller.add(jsonData);
        }
      }
    } catch (_) {}
    finally {
      isFetching = false;
    }
  }

  fetchData();
  timer = Timer.periodic(const Duration(seconds: 2), (_) => fetchData());

  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});

// ────────────────────────────────────────────────────────────
// 2. BLE + HTTP MERGED DATA PROVIDER (unchanged)
// ────────────────────────────────────────────────────────────
final bleServiceProvider = Provider<BleService>((ref) => BleService());

final smartHomeDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final httpStream = ref.watch(httpDataProvider.stream);

  final controller = StreamController<Map<String, dynamic>>();
  late StreamSubscription bleStatusSub;
  late StreamSubscription httpSub;

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
      controller.add(currentData);
    }
  }

  void updateFromHttp(Map<String, dynamic> httpData) {
    if (bleService.currentStatus != BleStatus.connected) {
      currentData = httpData;
      controller.add(currentData);
    } else {
      if (httpData.containsKey('status')) {
        currentData['status'] = httpData['status'];
        controller.add(currentData);
      }
    }
  }

  bleStatusSub = bleService.statusStream.listen((status) {
    if (status == BleStatus.connected || status == BleStatus.dataUpdated) {
      updateFromBle();
    } else if (status == BleStatus.disconnected) {
      ref.invalidate(httpDataProvider);
    }
  });

  httpSub = httpStream.listen((httpData) {
    updateFromHttp(httpData);
  });

  bleService.connect();

  ref.onDispose(() {
    bleStatusSub.cancel();
    httpSub.cancel();
    controller.close();
    bleService.dispose();
  });

  return controller.stream;
});

// ────────────────────────────────────────────────────────────
// 3. LIGHT TOGGLE SERVICE (unchanged)
// ────────────────────────────────────────────────────────────
final lightToggleProvider = Provider((ref) => LightToggleService(ref));

class LightToggleService {
  final Ref _ref;
  LightToggleService(this._ref);

  Future<void> toggle(String room, bool value, BuildContext context) async {
    final bleService = _ref.read(bleServiceProvider);
    final url = _ref.read(databaseUrlProvider);

    if (bleService.currentStatus == BleStatus.connected) {
      try {
        await bleService.setLightState(room, value);
        HapticFeedback.lightImpact();
        return;
      } catch (e) {
        if (context.mounted) {
          _showGlassSnackBar(context, 'BLE error, using Wi‑Fi: $e',
              color: Colors.orange);
        }
      }
    }

    try {
      final response = await http.patch(
        Uri.parse('$url/smartHome/lights.json'),
        body: jsonEncode({room: value}),
      );
      if (response.statusCode == 200) {
        HapticFeedback.lightImpact();
        _ref.invalidate(httpDataProvider);
      } else {
        throw Exception('HTTP toggle failed');
      }
    } catch (e) {
      if (context.mounted) {
        _showGlassSnackBar(context, 'Error toggling light: $e',
            color: Colors.red);
      }
      rethrow;
    }
  }
}

void _showGlassSnackBar(BuildContext context, String message,
    {Color color = Colors.white}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: color.withOpacity(0.85),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: const EdgeInsets.all(16),
    ),
  );
}

// ────────────────────────────────────────────────────────────
// 4. WALLPAPER GRADIENT BACKGROUND (responsive blobs)
// ────────────────────────────────────────────────────────────
class _WallpaperBackground extends StatelessWidget {
  final Widget child;
  const _WallpaperBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    // Scale glow blobs relative to screen width
    final blobSize1 = screenWidth * 0.8;
    final blobSize2 = screenWidth * 0.7;
    final blobSize3 = screenWidth * 0.6;

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: isDark
                ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF080C18),
                Color(0xFF10172E),
                Color(0xFF0A0E20),
              ],
            )
                : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFE3EAF8),
                Color(0xFFEDE8F5),
                Color(0xFFE8F0F8),
              ],
            ),
          ),
        ),
        Positioned(
          top: -80,
          left: -60,
          child: _GlowBlob(
            color: isDark ? const Color(0xFF1A3A7A) : const Color(0xFFB3C8F0),
            size: blobSize1,
          ),
        ),
        Positioned(
          top: 200,
          right: -80,
          child: _GlowBlob(
            color: isDark ? const Color(0xFF3A1A6A) : const Color(0xFFD4B8F0),
            size: blobSize2,
          ),
        ),
        Positioned(
          bottom: 100,
          left: 20,
          child: _GlowBlob(
            color: isDark ? const Color(0xFF0A3A2A) : const Color(0xFFB8E8D8),
            size: blobSize3,
          ),
        ),
        child,
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  final Color color;
  final double size;
  const _GlowBlob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withOpacity(0.45), color.withOpacity(0)],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 5. DASHBOARD PAGE
// ────────────────────────────────────────────────────────────
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  int _selectedIndex = 0;
  final List<Widget> _pages = const [
    _HomeContentWrapper(),
    _EnergyScreen(),
    _AlertsScreen(),
    _SettingsScreenWrapper(),
  ];

  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connect();
    ref.invalidate(httpDataProvider);
  }

  void _onTabTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final bleService = ref.watch(bleServiceProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _GlassAppBar(
        onRefresh: _manualRefresh,
        bleStatus: bleService.currentStatus,
        onConnectBLE: () => bleService.connect(),
      ),
      body: _WallpaperBackground(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _pages[_selectedIndex],
        ),
      ),
      bottomNavigationBar: _GlassBottomNavBar(
        selectedIndex: _selectedIndex,
        onTap: _onTabTapped,
      ),
    );
  }
}

// Wrappers to pass data
class _HomeContentWrapper extends ConsumerStatefulWidget {
  const _HomeContentWrapper();

  @override
  ConsumerState<_HomeContentWrapper> createState() => _HomeContentWrapperState();
}

class _HomeContentWrapperState extends ConsumerState<_HomeContentWrapper> {
  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connect();
    ref.invalidate(httpDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(smartHomeDataProvider);
    final bleService = ref.watch(bleServiceProvider);
    return _HomeContent(
      dataAsync: dataAsync,
      onRefresh: _manualRefresh,
      bleStatus: bleService.currentStatus,
      onConnectBLE: () => bleService.connect(),
    );
  }
}

class _SettingsScreenWrapper extends ConsumerStatefulWidget {
  const _SettingsScreenWrapper();

  @override
  ConsumerState<_SettingsScreenWrapper> createState() => _SettingsScreenWrapperState();
}

class _SettingsScreenWrapperState extends ConsumerState<_SettingsScreenWrapper> {
  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connect();
    ref.invalidate(httpDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final bleService = ref.watch(bleServiceProvider);
    return _SettingsScreen(
      themeMode: themeMode,
      onThemeModeChanged: (mode) =>
      ref.read(themeModeProvider.notifier).state = mode,
      bleStatus: bleService.currentStatus,
      onConnectBLE: () => bleService.connect(),
      onRefresh: _manualRefresh,
    );
  }
}

// ────────────────────────────────────────────────────────────
// 6. GLASS APP BAR (enhanced liquid blur)
// ────────────────────────────────────────────────────────────
class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;

  const _GlassAppBar({
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40), // increased blur
        child: Container(
          color: isDark
              ? Colors.black.withOpacity(0.2)
              : Colors.white.withOpacity(0.4),
          child: AppBar(
            backgroundColor: Colors.transparent,
            title: const Text(
              'Smart Home',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
            ),
            centerTitle: false,
            elevation: 0,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(0.5),
              child: Container(
                height: 0.5,
                color: isDark
                    ? Colors.white.withOpacity(0.12)
                    : Colors.black.withOpacity(0.08),
              ),
            ),
            actions: [
              _AppBarIconButton(
                onTap: bleStatus == BleStatus.connected ? null : onConnectBLE,
                child: bleStatus == BleStatus.connected
                    ? const Icon(Icons.bluetooth_connected,
                    color: Color(0xFF4DFFA0), size: 22)
                    : bleStatus == BleStatus.connecting
                    ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.bluetooth_disabled,
                    color: Colors.grey.shade500, size: 22),
              ),
              _AppBarIconButton(
                onTap: () => Navigator.pushNamed(context, '/provision'),
                child: const Icon(Icons.wifi_find, size: 22),
              ),
              _AppBarIconButton(
                onTap: () => Navigator.pushNamed(context, '/wifiConfig'),
                child: const Icon(Icons. , size: 22),
              ),
              _AppBarIconButton(
                onTap: () async {
                  await onRefresh();
                  if (context.mounted) {
                    _showGlassSnackBar(context, 'Refreshed ✓');
                  }
                },
                child: const Icon(Icons.refresh_rounded, size: 22),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 0.5);
}

class _AppBarIconButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _AppBarIconButton({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return _AnimatedPressWidget(
      onTap: onTap ?? () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: child,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 7. HOME CONTENT (responsive paddings & font sizes)
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
  bool _bathroomLightOn = false;
  double _ceilingBrightness = 0.8;
  double _tvVolume = 0.45;
  int _activeSceneIndex = 0;

  String? _lightKeyForRoom(String room) {
    switch (room) {
      case 'Living Room':
        return 'room1';
      case 'Bedroom':
        return 'room2';
      case 'Kitchen':
        return 'room3';
      default:
        return null;
    }
  }

  Future<void> _toggleRoomLight(String room) async {
    final lightKey = _lightKeyForRoom(room);
    if (lightKey != null) {
      final currentState = _getLightState(lightKey);
      final toggleService = ref.read(lightToggleProvider);
      await toggleService.toggle(lightKey, !currentState, context);
    } else {
      setState(() => _bathroomLightOn = !_bathroomLightOn);
      HapticFeedback.lightImpact();
      if (context.mounted) {
        _showGlassSnackBar(context, 'Bathroom light toggled');
      }
    }
  }

  bool _getLightState(String lightKey) {
    final data = widget.dataAsync.value;
    if (data != null) {
      final lights = data['lights'] as Map? ?? {};
      return lights[lightKey] == true;
    }
    return false;
  }

  int _getActiveLightsCount() {
    int count = 0;
    if (_getLightState('room1')) count++;
    if (_getLightState('room2')) count++;
    if (_getLightState('room3')) count++;
    if (_bathroomLightOn) count++;
    return count;
  }

  @override
  Widget build(BuildContext context) {
    // Responsive helpers
    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = screenWidth < 360 ? 12.0 : 20.0;
    final cardHorizontalPadding = screenWidth < 360 ? 14.0 : 20.0;
    final headerFontSize = screenWidth < 360 ? 22.0 : 27.0;
    final statValueFontSize = screenWidth < 360 ? 16.0 : 20.0;
    final roomNameFontSize = screenWidth < 360 ? 16.0 : 19.0;

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      displacement: 100,
      child: widget.dataAsync.when(
        data: (data) {
          final sensors = data['sensors'] as Map? ?? {};
          final temp = (sensors['temperature'] ?? 0.0).toDouble();
          final hum = (sensors['humidity'] ?? 0.0).toDouble();
          final flame = sensors['flame'] == true;

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + kToolbarHeight - 50,
              left: horizontalPadding,
              right: horizontalPadding,
              bottom: 24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, headerFontSize),
                const SizedBox(height: 20),
                _StatsRow(
                  temp: temp,
                  hum: hum,
                  valueFontSize: statValueFontSize,
                ),
                const SizedBox(height: 16),
                _QuickScenesRow(
                  activeIndex: _activeSceneIndex,
                  onSceneSelected: (i) => setState(() => _activeSceneIndex = i),
                ),
                const SizedBox(height: 16),
                _FlameSensorCard(flame: flame),
                const SizedBox(height: 14),
                _ActiveDevicesRow(activeCount: _getActiveLightsCount()),
                const SizedBox(height: 22),
                _RoomsSelector(
                  selectedRoom: _selectedRoom,
                  onRoomSelected: (room) =>
                      setState(() => _selectedRoom = room),
                ),
                const SizedBox(height: 14),
                _RoomDetailsPanel(
                  selectedRoom: _selectedRoom,
                  lightOn: _selectedRoom == 'Bathroom'
                      ? _bathroomLightOn
                      : _getLightState(
                      _lightKeyForRoom(_selectedRoom) ?? ''),
                  onLightToggle: () => _toggleRoomLight(_selectedRoom),
                  ceilingBrightness: _ceilingBrightness,
                  onCeilingBrightnessChanged: (val) =>
                      setState(() => _ceilingBrightness = val),
                  tvVolume: _tvVolume,
                  onTvVolumeChanged: (val) =>
                      setState(() => _tvVolume = val),
                  roomNameFontSize: roomNameFontSize,
                ),
              ],
            ),
          );
        },
        loading: () => const _SkeletonLoader(),
        error: (err, stack) => Center(
          child: Padding(
            padding: EdgeInsets.all(horizontalPadding),
            child: _GlassCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 48, color: Colors.redAccent),
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
                              .withOpacity(0.5)),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  _PillButton(
                    label: 'Try Again',
                    onTap: () => widget.onRefresh(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, double headerFontSize) {
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
        ? 'Good Afternoon'
        : 'Good Evening';
    final emoji = hour < 12
        ? '☀️'
        : hour < 17
        ? '🌤'
        : '🌙';
    final formattedDate =
        '${_weekday(now.weekday)}, ${now.day} ${_month(now.month)}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formattedDate,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.5),
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$greeting $emoji',
                style: TextStyle(
                  fontSize: headerFontSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
            ],
          ),
        ),
        _GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          borderRadius: BorderRadius.circular(40),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.bleStatus == BleStatus.connected
                      ? const Color(0xFF4DFFA0)
                      : Colors.orange,
                  boxShadow: [
                    BoxShadow(
                      color: (widget.bleStatus == BleStatus.connected
                          ? const Color(0xFF4DFFA0)
                          : Colors.orange)
                          .withOpacity(0.6),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                widget.bleStatus == BleStatus.connected ? 'BLE' : 'Wi‑Fi',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _weekday(int w) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[w - 1];
  }

  String _month(int m) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return months[m - 1];
  }
}

// ────────────────────────────────────────────────────────────
// STATS ROW (responsive)
// ────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final double temp;
  final double hum;
  final double valueFontSize;
  const _StatsRow({
    required this.temp,
    required this.hum,
    required this.valueFontSize,
  });

  @override
  Widget build(BuildContext context) {
    final tempDiff = temp - 25.0;
    final tempStatus =
    tempDiff > 0 ? '+${tempDiff.toStringAsFixed(1)}°' : 'Normal';
    final humStatus = (hum >= 30 && hum <= 70)
        ? 'Comfortable'
        : (hum > 70 ? 'Humid' : 'Dry');

    return Row(
      children: [
        Expanded(
          child: _StatCard(
            emoji: '🌡',
            value: '${temp.toStringAsFixed(1)}°',
            subtitle: tempStatus,
            accentColor: const Color(0xFFFF6B6B),
            valueFontSize: valueFontSize,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            emoji: '💧',
            value: '${hum.toStringAsFixed(0)}%',
            subtitle: humStatus,
            accentColor: const Color(0xFF64B5F6),
            valueFontSize: valueFontSize,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            emoji: '⚡',
            value: '3.4kW',
            subtitle: 'Today',
            accentColor: const Color(0xFFFFD54F),
            valueFontSize: valueFontSize,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String emoji;
  final String value;
  final String subtitle;
  final Color accentColor;
  final double valueFontSize;

  const _StatCard({
    required this.emoji,
    required this.value,
    required this.subtitle,
    required this.accentColor,
    required this.valueFontSize,
  });

  @override
  Widget build(BuildContext context) {
    return _AnimatedPressWidget(
      onTap: () {
        HapticFeedback.lightImpact();
        _showGlassSnackBar(context, '$value — $subtitle');
      },
      child: _GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
        glowColor: accentColor,
        animateGlow: true,
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                  fontSize: valueFontSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// QUICK SCENES ROW (unchanged)
// ────────────────────────────────────────────────────────────
class _QuickScenesRow extends StatelessWidget {
  final int activeIndex;
  final ValueChanged<int> onSceneSelected;

  const _QuickScenesRow({
    required this.activeIndex,
    required this.onSceneSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scenes = [
      ('☀️', 'Morning'),
      ('🎬', 'Movie'),
      ('🌙', 'Sleep'),
      ('🎉', 'Party'),
    ];

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: scenes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final isActive = activeIndex == index;
          final (emoji, label) = scenes[index];
          return _AnimatedPressWidget(
            onTap: () {
              HapticFeedback.lightImpact();
              onSceneSelected(index);
              _showGlassSnackBar(context, '$label scene activated');
            },
            child: _GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              borderRadius: BorderRadius.circular(40),
              isActive: isActive,
              activeColor: const Color(0xFFFFD54F),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.75),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// FLAME SENSOR CARD (unchanged)
// ────────────────────────────────────────────────────────────
class _FlameSensorCard extends StatelessWidget {
  final bool flame;
  const _FlameSensorCard({required this.flame});

  @override
  Widget build(BuildContext context) {
    return _AnimatedPressWidget(
      onTap: () {
        HapticFeedback.heavyImpact();
        _showGlassSnackBar(
          context,
          flame
              ? '⚠️ FLAME DETECTED! Check immediately.'
              : '✅ System safe. No flames.',
          color: flame ? Colors.red : Colors.green,
        );
      },
      child: _GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        glowColor: flame ? Colors.red : const Color(0xFF4DFFA0),
        animateGlow: true,
        dangerBorder: flame,
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: (flame ? Colors.red : const Color(0xFF4DFFA0))
                    .withOpacity(0.15),
              ),
              child: Center(
                child: Text(
                  flame ? '🔥' : '🛡️',
                  style: const TextStyle(fontSize: 24),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Flame Sensor',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    flame ? '⚠️ FLAME DETECTED' : '✅ All Clear',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: flame ? Colors.red.shade400 : const Color(0xFF4DFFA0),
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// ACTIVE DEVICES ROW (unchanged)
// ────────────────────────────────────────────────────────────
class _ActiveDevicesRow extends StatelessWidget {
  final int activeCount;
  const _ActiveDevicesRow({required this.activeCount});

  @override
  Widget build(BuildContext context) {
    const total = 4;
    return _GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const Text('💡', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Active lights',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withOpacity(0.75),
              ),
            ),
          ),
          Row(
            children: List.generate(total, (i) {
              final on = i < activeCount;
              return Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on
                      ? const Color(0xFF4DFFA0)
                      : Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.15),
                  boxShadow: on
                      ? [
                    BoxShadow(
                      color: const Color(0xFF4DFFA0).withOpacity(0.5),
                      blurRadius: 6,
                    )
                  ]
                      : null,
                ),
              );
            }),
          ),
          const SizedBox(width: 12),
          Text(
            '$activeCount/$total',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// ROOMS SELECTOR (unchanged)
// ────────────────────────────────────────────────────────────
class _RoomsSelector extends StatelessWidget {
  final String selectedRoom;
  final ValueChanged<String> onRoomSelected;

  const _RoomsSelector({
    required this.selectedRoom,
    required this.onRoomSelected,
  });

  @override
  Widget build(BuildContext context) {
    final rooms = [
      ('🛋', 'Living Room'),
      ('🛏', 'Bedroom'),
      ('🍳', 'Kitchen'),
      ('🚿', 'Bathroom'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Rooms',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withOpacity(0.9),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final (emoji, name) = rooms[index];
              final isSelected = name == selectedRoom;
              return _AnimatedPressWidget(
                onTap: () => onRoomSelected(name),
                child: _GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  borderRadius: BorderRadius.circular(40),
                  isActive: isSelected,
                  activeColor: Theme.of(context).colorScheme.primary,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 15)),
                      const SizedBox(width: 7),
                      Text(
                        name,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                          fontSize: 13,
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.65),
                        ),
                      ),
                    ],
                  ),
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
// ROOM DETAILS PANEL (responsive)
// ────────────────────────────────────────────────────────────
class _RoomDetailsPanel extends StatelessWidget {
  final String selectedRoom;
  final bool lightOn;
  final VoidCallback onLightToggle;
  final double ceilingBrightness;
  final ValueChanged<double> onCeilingBrightnessChanged;
  final double tvVolume;
  final ValueChanged<double> onTvVolumeChanged;
  final double roomNameFontSize;

  const _RoomDetailsPanel({
    required this.selectedRoom,
    required this.lightOn,
    required this.onLightToggle,
    required this.ceilingBrightness,
    required this.onCeilingBrightnessChanged,
    required this.tvVolume,
    required this.onTvVolumeChanged,
    required this.roomNameFontSize,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  selectedRoom,
                  style: TextStyle(
                    fontSize: roomNameFontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              _GlassToggle(
                value: lightOn,
                onChanged: (_) => onLightToggle(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _DeviceRow(
            emoji: lightOn ? '💡' : '🔦',
            name: 'Ceiling Light',
            valueLabel: '${(ceilingBrightness * 100).toInt()}%',
            accentColor: const Color(0xFFFFD54F),
          ),
          const SizedBox(height: 10),
          _GlassSlider(
            value: ceilingBrightness,
            onChanged: onCeilingBrightnessChanged,
            activeColor: const Color(0xFFFFD54F),
          ),
          if (selectedRoom == 'Living Room') ...[
            const SizedBox(height: 22),
            _DeviceRow(
              emoji: '📺',
              name: 'Smart TV',
              valueLabel: 'Vol ${(tvVolume * 100).toInt()}%',
              accentColor: const Color(0xFF64B5F6),
            ),
            const SizedBox(height: 10),
            _GlassSlider(
              value: tvVolume,
              onChanged: onTvVolumeChanged,
              activeColor: const Color(0xFF64B5F6),
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final String emoji;
  final String name;
  final String valueLabel;
  final Color accentColor;

  const _DeviceRow({
    required this.emoji,
    required this.name,
    required this.valueLabel,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accentColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 18))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(name,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
        ),
        Text(
          valueLabel,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: accentColor,
          ),
        ),
      ],
    );
  }
}

class _GlassSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final Color activeColor;

  const _GlassSlider({
    required this.value,
    required this.onChanged,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: activeColor,
        inactiveTrackColor:
        Theme.of(context).colorScheme.onSurface.withOpacity(0.12),
        thumbColor: Colors.white,
        overlayColor: activeColor.withOpacity(0.15),
        thumbShape:
        const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
        trackHeight: 4,
      ),
      child: Slider(
        value: value,
        onChanged: onChanged,
        min: 0,
        max: 1,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// GLASS TOGGLE SWITCH (iOS‑27 style)
// ────────────────────────────────────────────────────────────
class _GlassToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _GlassToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onChanged(!value);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: 52,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: value
              ? const Color(0xFF4DFFA0).withOpacity(0.3)
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
          border: Border.all(
            color: value
                ? const Color(0xFF4DFFA0).withOpacity(0.5)
                : Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.15),
            width: 0.8,
          ),
          boxShadow: value
              ? [
            BoxShadow(
              color: const Color(0xFF4DFFA0).withOpacity(0.3),
              blurRadius: 10,
              spreadRadius: 0,
            )
          ]
              : null,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? const Color(0xFF4DFFA0) : Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
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
// GLASS PILL BUTTON (unchanged)
// ────────────────────────────────────────────────────────────
class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PillButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _AnimatedPressWidget(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(40),
          color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 8. GLASS BOTTOM NAV BAR (liquid blur, responsive height)
// ────────────────────────────────────────────────────────────
class _GlassBottomNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _GlassBottomNavBar({
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.home_rounded, '🏠', 'Home'),
      (Icons.bolt_rounded, '⚡', 'Energy'),
      (Icons.notifications_rounded, '🔔', 'Alerts'),
      (Icons.settings_rounded, '⚙️', 'Settings'),
    ];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final navHeight = screenWidth < 360 ? 56.0 : 64.0;

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40), // liquid blur
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.black.withOpacity(0.2)
                : Colors.white.withOpacity(0.4),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.05),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: navHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (index) {
                  final isSelected = selectedIndex == index;
                  final (icon, _, label) = items[index];
                  return _AnimatedPressWidget(
                    onTap: () => onTap(index),
                    scaleFactor: 0.92,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(40),
                        color: isSelected
                            ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(isDark ? 0.2 : 0.12)
                            : Colors.transparent,
                        border: isSelected
                            ? Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.25),
                          width: 0.8,
                        )
                            : null,
                        boxShadow: isSelected
                            ? [
                          BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.2),
                            blurRadius: 12,
                            spreadRadius: 0,
                          ),
                        ]
                            : null,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: 22,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.45),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.45),
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 9. ENERGY, ALERTS, SETTINGS SCREENS (unchanged, minor fixes)
// ────────────────────────────────────────────────────────────

class _EnergyScreen extends StatelessWidget {
  const _EnergyScreen();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      child: Column(
        children: [
          _GlassCard(
            padding: const EdgeInsets.all(24),
            glowColor: Theme.of(context).colorScheme.primary,
            animateGlow: true,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Today's Usage",
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.15),
                      ),
                      child: Text(
                        '⚡ Live',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _EnergyMetric(
                      value: '3.4',
                      unit: 'kWh',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    Container(
                      width: 0.5,
                      height: 50,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.15),
                    ),
                    const _EnergyMetric(
                      value: '€2.15',
                      unit: 'Cost',
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: 0.45,
                    minHeight: 6,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation(
                        Theme.of(context).colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Daily target',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.5),
                      ),
                    ),
                    Text(
                      '45%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _GlassCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This Week',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '24.1 kWh',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '↓ 8% vs last week',
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF4DFFA0),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    value: 0.62,
                    strokeWidth: 7,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation(
                        Theme.of(context).colorScheme.primary),
                    strokeCap: StrokeCap.round,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Top Devices',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                _EnergyDeviceRow(
                  emoji: '❄️',
                  name: 'Living Room AC',
                  usage: '2.1 kWh',
                  fraction: 0.62,
                ),
                const SizedBox(height: 14),
                _EnergyDeviceRow(
                  emoji: '🧊',
                  name: 'Kitchen Fridge',
                  usage: '1.8 kWh',
                  fraction: 0.53,
                ),
                const SizedBox(height: 14),
                _EnergyDeviceRow(
                  emoji: '🚿',
                  name: 'Water Heater',
                  usage: '1.2 kWh',
                  fraction: 0.35,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EnergyMetric extends StatelessWidget {
  final String value;
  final String unit;
  final Color? color;
  const _EnergyMetric({required this.value, required this.unit, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
            color: color,
          ),
        ),
        Text(
          unit,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
      ],
    );
  }
}

class _EnergyDeviceRow extends StatelessWidget {
  final String emoji;
  final String name;
  final String usage;
  final double fraction;
  const _EnergyDeviceRow({
    required this.emoji,
    required this.name,
    required this.usage,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500)),
            ),
            Text(
              usage,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.08),
            valueColor: AlwaysStoppedAnimation(
                Theme.of(context).colorScheme.primary),
          ),
        ),
      ],
    );
  }
}

// --- ALERTS SCREEN ---
class _AlertsScreen extends StatelessWidget {
  const _AlertsScreen();

  @override
  Widget build(BuildContext context) {
    final alerts = [
      ('⚠️', Colors.orange, 'Motion in Living Room', '2 minutes ago'),
      ('🔥', Colors.red, 'Flame sensor test — All Clear', '1 hour ago'),
      ('🔌', Colors.blue, 'Device offline: Bedroom Light', '3 hours ago'),
      ('💧', Colors.teal, 'High humidity in Kitchen', '5 hours ago'),
    ];

    return ListView.separated(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      itemCount: alerts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final (emoji, color, title, time) = alerts[index];
        return _AnimatedPressWidget(
          onTap: () {
            HapticFeedback.lightImpact();
            _showGlassSnackBar(context, title, color: color);
          },
          child: _GlassCard(
            padding: const EdgeInsets.all(16),
            glowColor: color,
            animateGlow: index == 0,
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                    color: color.withOpacity(0.15),
                  ),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.3),
                  size: 20,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- SETTINGS SCREEN ---
class _SettingsScreen extends StatelessWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;
  final Future<void> Function() onRefresh;

  const _SettingsScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.bleStatus,
    required this.onConnectBLE,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      children: [
        _GlassCard(
          child: Column(
            children: [
              _SettingsTile(
                emoji: '🎨',
                title: 'Appearance',
                subtitle: 'Theme mode',
                trailing: _GlassCard(
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(12),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<ThemeMode>(
                      value: themeMode,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      borderRadius: BorderRadius.circular(16),
                      items: const [
                        DropdownMenuItem(
                          value: ThemeMode.light,
                          child: Text('Light',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                        DropdownMenuItem(
                          value: ThemeMode.dark,
                          child: Text('Dark',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                        DropdownMenuItem(
                          value: ThemeMode.system,
                          child: Text('System',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                        ),
                      ],
                      onChanged: (mode) => onThemeModeChanged(mode!),
                    ),
                  ),
                ),
              ),
              _GlassDivider(),
              _SettingsTile(
                emoji: '🔵',
                title: 'Bluetooth',
                subtitle: bleStatus == BleStatus.connected
                    ? 'Connected'
                    : 'Not connected',
                trailing: bleStatus == BleStatus.connected
                    ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: const Color(0xFF4DFFA0).withOpacity(0.15),
                    border: Border.all(
                      color: const Color(0xFF4DFFA0).withOpacity(0.4),
                      width: 0.8,
                    ),
                  ),
                  child: const Text(
                    '● Connected',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4DFFA0),
                    ),
                  ),
                )
                    : _PillButton(
                  label: 'Connect',
                  onTap: onConnectBLE,
                ),
              ),
              _GlassDivider(),
              _SettingsTile(
                emoji: '🔄',
                title: 'Manual Refresh',
                subtitle: 'Pull from BLE / Cloud',
                trailing: _AnimatedPressWidget(
                  onTap: () => onRefresh(),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.12),
                    ),
                    child: Icon(
                      Icons.refresh_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GlassCard(
          child: Column(
            children: [
              _SettingsTile(
                emoji: '📡',
                title: 'Provision ESP32',
                subtitle: 'Setup a new device',
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: () {},
              ),
              _GlassDivider(),
              _SettingsTile(
                emoji: '📶',
                title: 'Wi‑Fi Config',
                subtitle: 'Change network settings',
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: () {},
              ),
              _GlassDivider(),
              _SettingsTile(
                emoji: 'ℹ️',
                title: 'About',
                subtitle: 'Smart Home v1.0.0',
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: () {},
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlassDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );

    if (onTap != null) {
      return _AnimatedPressWidget(onTap: onTap!, child: tile);
    }
    return tile;
  }
}

// ────────────────────────────────────────────────────────────
// 10. LIQUID GLASS CARD – enhanced for iOS‑27
// ────────────────────────────────────────────────────────────
class _GlassCard extends StatelessWidget {
  final Widget child;
  final double blur;
  final Border? border;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool animateGlow;
  final Color? glowColor;
  final bool isActive;
  final Color? activeColor;
  final bool dangerBorder;

  const _GlassCard({
    required this.child,
    this.blur = 40, // increased for liquid glass
    this.border,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = const BorderRadius.all(Radius.circular(32)),
    this.animateGlow = false,
    this.glowColor,
    this.isActive = false,
    this.activeColor,
    this.dangerBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Liquid gradient instead of solid color
    final Gradient baseGradient = isDark
        ? const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0x20FFFFFF), // 12% white
        Color(0x05FFFFFF),
      ],
    )
        : const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0x50FFFFFF), // ~31% white
        Color(0x20FFFFFF),
      ],
    );

    Border effectiveBorder;
    if (border != null) {
      effectiveBorder = border!;
    } else if (dangerBorder) {
      effectiveBorder = Border.all(
        color: Colors.red.withOpacity(0.5),
        width: 0.8,
      );
    } else if (isActive && activeColor != null) {
      effectiveBorder = Border.all(
        color: activeColor!.withOpacity(0.5),
        width: 1.2,
      );
    } else {
      effectiveBorder = Border.all(
        color: isDark
            ? Colors.white.withOpacity(0.1)
            : Colors.white.withOpacity(0.3),
        width: 0.8,
      );
    }

    final List<BoxShadow> shadows = [
      BoxShadow(
        color: isDark
            ? Colors.black.withOpacity(0.35)
            : Colors.black.withOpacity(0.06),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ];
    if (animateGlow && glowColor != null) {
      shadows.add(BoxShadow(
        color: glowColor!.withOpacity(isDark ? 0.22 : 0.18),
        blurRadius: 28,
        spreadRadius: 0,
      ));
    }
    if (isActive && activeColor != null) {
      shadows.add(BoxShadow(
        color: activeColor!.withOpacity(0.2),
        blurRadius: 16,
        spreadRadius: 0,
      ));
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: isActive && activeColor != null
                ? LinearGradient(
              colors: [
                activeColor!.withOpacity(isDark ? 0.14 : 0.1),
                activeColor!.withOpacity(isDark ? 0.05 : 0.02),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
                : baseGradient,
            borderRadius: borderRadius,
            border: effectiveBorder,
            boxShadow: shadows,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 11. ANIMATED PRESS WIDGET – optimized (no AnimationController)
// ────────────────────────────────────────────────────────────
class _AnimatedPressWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double scaleFactor;

  const _AnimatedPressWidget({
    required this.child,
    required this.onTap,
    this.scaleFactor = 0.96,
  });

  @override
  State<_AnimatedPressWidget> createState() => _AnimatedPressWidgetState();
}

class _AnimatedPressWidgetState extends State<_AnimatedPressWidget> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? widget.scaleFactor : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeInOut,
        child: widget.child,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// 12. SKELETON LOADER (unchanged)
// ────────────────────────────────────────────────────────────
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? Colors.white.withOpacity(0.06)
          : Colors.black.withOpacity(0.07),
      highlightColor: isDark
          ? Colors.white.withOpacity(0.13)
          : Colors.black.withOpacity(0.03),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
          left: 20,
          right: 20,
          bottom: 24,
        ),
        child: Column(
          children: [
            _SkeletonBox(height: 68, radius: 28),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _SkeletonBox(height: 100, radius: 24)),
                const SizedBox(width: 12),
                Expanded(child: _SkeletonBox(height: 100, radius: 24)),
                const SizedBox(width: 12),
                Expanded(child: _SkeletonBox(height: 100, radius: 24)),
              ],
            ),
            const SizedBox(height: 14),
            _SkeletonBox(height: 44, radius: 28),
            const SizedBox(height: 14),
            _SkeletonBox(height: 72, radius: 28),
            const SizedBox(height: 14),
            _SkeletonBox(height: 56, radius: 28),
            const SizedBox(height: 22),
            _SkeletonBox(height: 48, radius: 28),
            const SizedBox(height: 14),
            _SkeletonBox(height: 180, radius: 28),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double height;
  final double radius;
  const _SkeletonBox({required this.height, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}