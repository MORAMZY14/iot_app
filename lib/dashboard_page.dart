import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'ble_service.dart';

// ============================================================
// 0. THEME MANAGEMENT
// ============================================================
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final themeProvider = Provider<ThemeData>((ref) {
  final mode = ref.watch(themeModeProvider);
  final isDark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system &&
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark);
  return isDark ? _darkTheme : _lightTheme;
});

final _lightTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorSchemeSeed: const Color(0xFF0D47A1),
  scaffoldBackgroundColor: const Color(0xFFF2F2F7),
  appBarTheme: AppBarTheme(
    backgroundColor: Colors.white.withOpacity(0.7),
    elevation: 0,
    scrolledUnderElevation: 0.5,
  ),
  dividerTheme: DividerThemeData(color: Colors.grey.shade300),
);

final _darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorSchemeSeed: const Color(0xFF2196F3),
  scaffoldBackgroundColor: const Color(0xFF0A0A0A),
  appBarTheme: AppBarTheme(
    backgroundColor: Colors.black.withOpacity(0.6),
    elevation: 0,
    scrolledUnderElevation: 0.5,
  ),
  dividerTheme: DividerThemeData(color: Colors.grey.shade800),
);

// ============================================================
// 1. HTTP POLLING SERVICE (unchanged)
// ============================================================
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
    } catch (e) {
      // ignore
    } finally {
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

// ============================================================
// 2. BLE + HTTP MERGED DATA PROVIDER (unchanged)
// ============================================================
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

// ============================================================
// 3. LIGHT TOGGLE SERVICE (unchanged)
// ============================================================
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('BLE error, using Wi‑Fi: $e'),
                backgroundColor: Colors.orange),
          );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error toggling light: $e'),
              backgroundColor: Colors.red),
        );
      }
      rethrow;
    }
  }
}

// ============================================================
// 4. MAIN DASHBOARD PAGE
// ============================================================
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(smartHomeDataProvider);
    final bleService = ref.watch(bleServiceProvider);
    final themeMode = ref.watch(themeModeProvider);

    Future<void> manualRefresh() async {
      await bleService.connect();
      ref.invalidate(httpDataProvider);
    }

    return Scaffold(
      appBar: _ModernAppBar(
        onRefresh: manualRefresh,
        bleStatus: bleService.currentStatus,
        onConnectBLE: () => bleService.connect(),
        themeMode: themeMode,
        onThemeModeChanged: (mode) =>
        ref.read(themeModeProvider.notifier).state = mode,
      ),
      body: dataAsync.when(
        data: (data) => RefreshIndicator(
          onRefresh: manualRefresh,
          child: _DashboardContent(data: data),
        ),
        loading: () => const _SkeletonLoader(),
        error: (err, stack) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('Error: ${err.toString()}'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => manualRefresh(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 5. APP BAR WITH THEME TOGGLE + LIQUID GLASS
// ============================================================
class _ModernAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final Future<void> Function() onRefresh;
  final BleStatus bleStatus;
  final VoidCallback onConnectBLE;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const _ModernAppBar({
    required this.onRefresh,
    required this.bleStatus,
    required this.onConnectBLE,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AppBar(
          title: const Text('Smart Home',
              style: TextStyle(fontWeight: FontWeight.w600)),
          centerTitle: false,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [Colors.white.withOpacity(0.08), Colors.white.withOpacity(0.02)]
                    : [Colors.white.withOpacity(0.7), Colors.white.withOpacity(0.4)],
              ),
              border: Border(
                bottom: BorderSide(
                  color: isDark ? Colors.white12 : Colors.black12,
                  width: 0.5,
                ),
              ),
            ),
          ),
          actions: [
            IconButton(
              icon: Icon(
                themeMode == ThemeMode.dark
                    ? Icons.dark_mode
                    : themeMode == ThemeMode.light
                    ? Icons.light_mode
                    : Icons.brightness_auto,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
              ),
              onPressed: () {
                if (themeMode == ThemeMode.light) {
                  onThemeModeChanged(ThemeMode.dark);
                } else if (themeMode == ThemeMode.dark) {
                  onThemeModeChanged(ThemeMode.system);
                } else {
                  onThemeModeChanged(ThemeMode.light);
                }
                HapticFeedback.lightImpact();
              },
              tooltip: 'Toggle theme',
            ),
            if (bleStatus == BleStatus.connected)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.bluetooth_connected,
                    color: Theme.of(context).colorScheme.primary),
              )
            else if (bleStatus == BleStatus.connecting)
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary),
              )
            else
              IconButton(
                icon: Icon(Icons.bluetooth_disabled,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                onPressed: onConnectBLE,
                tooltip: 'Connect Bluetooth',
              ),
            IconButton(
              icon: const Icon(Icons.wifi_find),
              tooltip: 'Provision ESP32',
              onPressed: () => Navigator.pushNamed(context, '/provision'),
            ),
            IconButton(
              icon: const Icon(Icons.wifi),
              tooltip: 'WiFi Settings',
              onPressed: () => Navigator.pushNamed(context, '/wifiConfig'),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                await onRefresh();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Refreshed'),
                        duration: Duration(seconds: 1)),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

// ============================================================
// 6. TRUE LIQUID GLASS CARD (with animated refractive gradient)
// ============================================================
class _LiquidGlassCard extends StatefulWidget {
  final Widget child;
  final double blur;
  final Border? border;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool animateGlow;
  final Color? glowColor;

  const _LiquidGlassCard({
    required this.child,
    this.blur = 25,
    this.border,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = const BorderRadius.all(Radius.circular(32)),
    this.animateGlow = false,
    this.glowColor,
  });

  @override
  State<_LiquidGlassCard> createState() => _LiquidGlassCardState();
}

class _LiquidGlassCardState extends State<_LiquidGlassCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnim;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _shimmerAnim = Tween<double>(begin: -0.2, end: 0.2).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Base glass color
    final baseColor = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.white.withOpacity(0.7);

    // Animated gradient for refractive liquid effect
    final gradient = LinearGradient(
      begin: Alignment(-0.2 + _shimmerAnim.value, -0.4),
      end: Alignment(0.4 - _shimmerAnim.value, 0.6),
      colors: [
        Colors.white.withOpacity(isDark ? 0.15 : 0.5),
        Colors.white.withOpacity(isDark ? 0.02 : 0.2),
        Colors.white.withOpacity(isDark ? 0.1 : 0.4),
      ],
      stops: const [0.0, 0.5, 1.0],
    );

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
            sigmaX: widget.blur, sigmaY: widget.blur),
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            color: baseColor,
            borderRadius: widget.borderRadius,
            border: widget.border ??
                Border.all(
                  color: isDark ? Colors.white24 : Colors.white54,
                  width: 0.8,
                ),
            gradient: gradient, // the liquid gradient overlay
            boxShadow: [
              BoxShadow(
                color: (widget.glowColor ?? Colors.transparent)
                    .withOpacity(widget.animateGlow ? 0.2 : 0.0),
                blurRadius: 20,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: isDark
                    ? Colors.black.withOpacity(0.4)
                    : Colors.black.withOpacity(0.05),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// ============================================================
// 7. ANIMATED LIQUID SWITCH (spring physics)
// ============================================================
class LiquidSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool disabled;

  const LiquidSwitch({
    required this.value,
    required this.onChanged,
    this.disabled = false,
    super.key,
  });

  @override
  State<LiquidSwitch> createState() => _LiquidSwitchState();
}

class _LiquidSwitchState extends State<LiquidSwitch>
    with TickerProviderStateMixin {
  late AnimationController _positionController;
  late Animation<double> _positionAnimation;
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _positionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _positionAnimation = Tween<double>(
      begin: widget.value ? 1.0 : 0.0,
      end: widget.value ? 1.0 : 0.0,
    ).animate(CurvedAnimation(
      parent: _positionController,
      curve: Curves.easeOutBack, // spring feel
    ));

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeOut),
    );

    if (widget.value) _glowController.value = 1.0;
  }

  @override
  void didUpdateWidget(LiquidSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      // Animate to new position
      _positionAnimation = Tween<double>(
        begin: _positionAnimation.value,
        end: widget.value ? 1.0 : 0.0,
      ).animate(CurvedAnimation(
        parent: _positionController,
        curve: Curves.easeOutBack,
      ));
      _positionController.reset();
      _positionController.forward();

      // Animate glow
      if (widget.value) {
        _glowController.forward();
      } else {
        _glowController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _positionController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const double width = 52;
    const double height = 32;
    const double thumbSize = 26;

    return GestureDetector(
      onTap: widget.disabled ? null : () => widget.onChanged(!widget.value),
      child: AnimatedBuilder(
        animation: Listenable.merge([_positionAnimation, _glowAnimation]),
        builder: (context, child) {
          final trackColor = Color.lerp(
            isDark ? Colors.grey.shade700 : Colors.grey.shade300,
            Colors.amber,
            _positionAnimation.value,
          )!;
          final thumbPosition = _positionAnimation.value *
              (width - thumbSize - 4); // padding

          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height / 2),
              color: trackColor,
              boxShadow: widget.value
                  ? [
                BoxShadow(
                  color: Colors.amber.withOpacity(0.5 * _glowAnimation.value),
                  blurRadius: 12,
                  spreadRadius: 2,
                )
              ]
                  : [],
            ),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  left: thumbPosition,
                  top: (height - thumbSize) / 2,
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// 8. RESPONSIVE DASHBOARD CONTENT (with liquid glass cards)
// ============================================================
class _DashboardContent extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DashboardContent({required this.data});

  @override
  Widget build(BuildContext context) {
    final sensors = data['sensors'] as Map? ?? {};
    final lights = data['lights'] as Map? ?? {};
    final status = data['status'] as Map? ?? {};

    final temp = (sensors['temperature'] ?? 0.0).toDouble();
    final hum = (sensors['humidity'] ?? 0.0).toDouble();
    final flame = sensors['flame'] == true;
    final room1 = lights['room1'] == true;
    final room2 = lights['room2'] == true;
    final room3 = lights['room3'] == true;
    final online = status['online'] == true;

    return LayoutBuilder(
      builder: (context, constraints) {
        final widgets = <Widget>[];

        Widget sensorRow = Row(
          children: [
            Expanded(child: _SensorCard.temp(temp)),
            const SizedBox(width: 16),
            Expanded(child: _SensorCard.humidity(hum)),
          ],
        );

        Widget flameCard = _FlameCard(flame: flame);
        Widget lightsCard = _LightsCard(
            room1: room1, room2: room2, room3: room3);
        Widget statusCard = _StatusCard(online: online);

        if (constraints.maxWidth < 600) {
          widgets.addAll([
            sensorRow,
            const SizedBox(height: 16),
            flameCard,
            const SizedBox(height: 16),
            lightsCard,
            const SizedBox(height: 16),
            statusCard,
          ]);
        } else if (constraints.maxWidth < 900) {
          widgets.addAll([
            sensorRow,
            const SizedBox(height: 16),
            flameCard,
            const SizedBox(height: 16),
            lightsCard,
            const SizedBox(height: 16),
            statusCard,
          ]);
        } else {
          widgets.addAll([
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _SensorCard.temp(temp)),
                const SizedBox(width: 16),
                Expanded(child: _SensorCard.humidity(hum)),
                const SizedBox(width: 16),
                Expanded(child: flameCard),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: lightsCard),
                const SizedBox(width: 16),
                Expanded(child: statusCard),
              ],
            ),
          ]);
        }

        return ListView(
          padding: EdgeInsets.all(constraints.maxWidth < 600 ? 16 : 24),
          children: widgets,
        );
      },
    );
  }
}

// ----- LIQUID SENSOR CARD -----
class _SensorCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _SensorCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  factory _SensorCard.temp(double value) => _SensorCard(
    title: 'Temperature',
    value: '${value.toStringAsFixed(1)}°C',
    icon: Icons.thermostat,
    color: Colors.deepOrange,
  );

  factory _SensorCard.humidity(double value) => _SensorCard(
    title: 'Humidity',
    value: '${value.toStringAsFixed(0)}%',
    icon: Icons.water_drop,
    color: Colors.blueAccent,
  );

  @override
  Widget build(BuildContext context) {
    return _LiquidGlassCard(
      blur: 25,
      animateGlow: true,
      glowColor: color,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [color.withOpacity(0.25), color.withOpacity(0.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(icon, size: 32, color: color),
          ),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.7),
                  fontSize: 14)),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              value,
              key: ValueKey(value),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----- LIQUID FLAME CARD -----
class _FlameCard extends StatelessWidget {
  final bool flame;
  const _FlameCard({required this.flame});

  @override
  Widget build(BuildContext context) {
    final danger = flame ? Colors.red : Colors.green;
    return _LiquidGlassCard(
      blur: 25,
      animateGlow: flame,
      glowColor: danger,
      border: flame
          ? Border.all(color: danger.withOpacity(0.6), width: 1.2)
          : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Flame Sensor',
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.7),
                      fontSize: 14)),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (flame) ...[
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.red, size: 28),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    flame ? 'FLAME DETECTED!' : 'All Clear',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: danger,
                    ),
                  ),
                ],
              ),
            ],
          ),
          CircleAvatar(
            radius: 36,
            backgroundColor: danger.withOpacity(0.15),
            child: Icon(
              flame ? Icons.local_fire_department : Icons.shield,
              color: danger,
              size: 40,
            ),
          ),
        ],
      ),
    );
  }
}

// ----- LIQUID LIGHTS CARD (with spring-animated switches) -----
class _LightsCard extends ConsumerStatefulWidget {
  final bool room1;
  final bool room2;
  final bool room3;

  const _LightsCard({
    required this.room1,
    required this.room2,
    required this.room3,
  });

  @override
  ConsumerState<_LightsCard> createState() => _LightsCardState();
}

class _LightsCardState extends ConsumerState<_LightsCard> {
  late Map<String, bool> _lightStates;
  final Set<String> _pendingToggles = {};

  @override
  void initState() {
    super.initState();
    _lightStates = {
      'room1': widget.room1,
      'room2': widget.room2,
      'room3': widget.room3,
    };
  }

  @override
  void didUpdateWidget(covariant _LightsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_pendingToggles.contains('room1') &&
        widget.room1 != oldWidget.room1) {
      setState(() => _lightStates['room1'] = widget.room1);
    }
    if (!_pendingToggles.contains('room2') &&
        widget.room2 != oldWidget.room2) {
      setState(() => _lightStates['room2'] = widget.room2);
    }
    if (!_pendingToggles.contains('room3') &&
        widget.room3 != oldWidget.room3) {
      setState(() => _lightStates['room3'] = widget.room3);
    }
  }

  Future<void> _toggle(String room) async {
    final newValue = !_lightStates[room]!;
    setState(() => _lightStates[room] = newValue);
    _pendingToggles.add(room);

    try {
      final toggleService = ref.read(lightToggleProvider);
      await toggleService.toggle(room, newValue, context);
    } catch (_) {
      if (mounted) {
        setState(() => _lightStates[room] = !newValue);
      }
    } finally {
      if (mounted) {
        setState(() => _pendingToggles.remove(room));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _LiquidGlassCard(
      blur: 25,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Light Controls',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 12),
          _LightSwitchTile(
            room: 'Room 1',
            value: _lightStates['room1']!,
            pending: _pendingToggles.contains('room1'),
            onChanged: (_) => _toggle('room1'),
          ),
          const Divider(height: 32),
          _LightSwitchTile(
            room: 'Room 2',
            value: _lightStates['room2']!,
            pending: _pendingToggles.contains('room2'),
            onChanged: (_) => _toggle('room2'),
          ),
          const Divider(height: 32),
          _LightSwitchTile(
            room: 'Room 3',
            value: _lightStates['room3']!,
            pending: _pendingToggles.contains('room3'),
            onChanged: (_) => _toggle('room3'),
          ),
        ],
      ),
    );
  }
}

class _LightSwitchTile extends StatelessWidget {
  final String room;
  final bool value;
  final bool pending;
  final ValueChanged<bool> onChanged;

  const _LightSwitchTile({
    required this.room,
    required this.value,
    required this.pending,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          child: Icon(
            value ? Icons.lightbulb : Icons.lightbulb_outline,
            color: value ? Colors.amber : Colors.grey,
            size: 28,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(room,
              style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
        if (pending)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          LiquidSwitch(
            value: value,
            onChanged: onChanged,
          ),
      ],
    );
  }
}

// ----- LIQUID STATUS CARD -----
class _StatusCard extends StatelessWidget {
  final bool online;
  const _StatusCard({required this.online});

  @override
  Widget build(BuildContext context) {
    final color = online ? Colors.green : Colors.red;
    return _LiquidGlassCard(
      blur: 25,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      animateGlow: online,
      glowColor: color,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.0, end: online ? 1.2 : 1.0),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            builder: (context, scale, child) => Transform.scale(
              scale: scale,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: online
                      ? [
                    BoxShadow(
                        color: color.withOpacity(0.6),
                        blurRadius: 8,
                        spreadRadius: 2)
                  ]
                      : [],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            online ? 'ESP32 ONLINE' : 'ESP32 OFFLINE',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ----- RESPONSIVE SKELETON LOADER (with glass) -----
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Shimmer.fromColors(
          baseColor: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
          highlightColor:
          isDark ? Colors.grey.shade700 : Colors.grey.shade100,
          child: ListView(
            padding: EdgeInsets.all(constraints.maxWidth < 600 ? 16 : 24),
            children: _buildSkeletonList(constraints.maxWidth),
          ),
        );
      },
    );
  }

  List<Widget> _buildSkeletonList(double width) {
    Widget card(double height) => _LiquidGlassCard(
      blur: 10,
      child: SizedBox(height: height),
    );

    if (width < 600) {
      return [
        Row(children: [
          Expanded(child: card(120)),
          const SizedBox(width: 16),
          Expanded(child: card(120)),
        ]),
        const SizedBox(height: 16),
        card(100),
        const SizedBox(height: 16),
        card(220),
        const SizedBox(height: 16),
        card(70),
      ];
    } else if (width < 900) {
      return [
        Row(children: [
          Expanded(child: card(140)),
          const SizedBox(width: 16),
          Expanded(child: card(140)),
        ]),
        const SizedBox(height: 16),
        card(120),
        const SizedBox(height: 16),
        card(260),
        const SizedBox(height: 16),
        card(70),
      ];
    } else {
      return [
        Row(children: [
          Expanded(child: card(160)),
          const SizedBox(width: 16),
          Expanded(child: card(160)),
          const SizedBox(width: 16),
          Expanded(child: card(160)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(flex: 2, child: card(260)),
          const SizedBox(width: 16),
          Expanded(child: card(260)),
        ]),
      ];
    }
  }
}