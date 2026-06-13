import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'ble_service.dart';

// ============================================================
// 0. THEME MANAGEMENT (unchanged)
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
// 4. MAIN APP (ADDED – fixes theme switching)
// ============================================================
void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'Smart Home',
      theme: theme,
      darkTheme: theme,
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      home: const DashboardPage(),
    );
  }
}

// ============================================================
// 5. MAIN DASHBOARD PAGE WITH BOTTOM NAVIGATION (unchanged)
// ============================================================
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  int _selectedIndex = 0; // 0: Home, 1: Energy, 2: Alerts, 3: Settings

  Future<void> _manualRefresh() async {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connect();
    ref.invalidate(httpDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(smartHomeDataProvider);
    final bleService = ref.watch(bleServiceProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            // Home Screen
            _HomeContent(
              dataAsync: dataAsync,
              onRefresh: _manualRefresh,
              bleStatus: bleService.currentStatus,
              onConnectBLE: () => bleService.connect(),
            ),
            const _EnergyScreen(),
            const _AlertsScreen(),
            _SettingsScreen(
              themeMode: themeMode,
              onThemeModeChanged: (mode) =>
              ref.read(themeModeProvider.notifier).state = mode,
              bleStatus: bleService.currentStatus,
              onConnectBLE: () => bleService.connect(),
              onRefresh: _manualRefresh,
            ),
          ],
        ),
      ),
      bottomNavigationBar: _ModernBottomNavBar(
        selectedIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }
}

// ============================================================
// 6. HOME CONTENT (exactly as you had – unchanged)
// ============================================================
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bathroom light toggled (mock)'),
            duration: Duration(seconds: 1),
          ),
        );
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
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: widget.dataAsync.when(
        data: (data) {
          final sensors = data['sensors'] as Map? ?? {};
          final temp = (sensors['temperature'] ?? 0.0).toDouble();
          final hum = (sensors['humidity'] ?? 0.0).toDouble();
          final flame = sensors['flame'] == true;

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 24),
                _StatsRow(temp: temp, hum: hum),
                const SizedBox(height: 24),
                const _QuickScenesRow(),
                const SizedBox(height: 24),
                _FlameSensorCard(flame: flame),
                const SizedBox(height: 20),
                _ActiveDevicesRow(activeCount: _getActiveLightsCount()),
                const SizedBox(height: 24),
                _RoomsSelector(
                  selectedRoom: _selectedRoom,
                  onRoomSelected: (room) => setState(() => _selectedRoom = room),
                ),
                const SizedBox(height: 16),
                _RoomDetailsPanel(
                  selectedRoom: _selectedRoom,
                  lightOn: _selectedRoom == 'Bathroom'
                      ? _bathroomLightOn
                      : _getLightState(_lightKeyForRoom(_selectedRoom)!),
                  onLightToggle: () => _toggleRoomLight(_selectedRoom),
                  ceilingBrightness: _ceilingBrightness,
                  onCeilingBrightnessChanged: (val) =>
                      setState(() => _ceilingBrightness = val),
                  tvVolume: _tvVolume,
                  onTvVolumeChanged: (val) => setState(() => _tvVolume = val),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
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
                onPressed: () => widget.onRefresh(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final now = DateTime.now();
    final formattedDate = '${_weekday(now.weekday)}, ${now.day} ${_month(now.month)}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formattedDate,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text(
                  'Good Morning ',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const Text('🪙', style: TextStyle(fontSize: 24)),
              ],
            ),
          ],
        ),
        const Text('🌙', style: TextStyle(fontSize: 32)),
      ],
    );
  }

  String _weekday(int w) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[w - 1];
  }

  String _month(int m) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[m - 1];
  }
}

// ----- Stats Row -----
class _StatsRow extends StatelessWidget {
  final double temp;
  final double hum;
  const _StatsRow({required this.temp, required this.hum});

  @override
  Widget build(BuildContext context) {
    const energyValue = '3.4kW';
    const energyLabel = 'Today';
    final tempDiff = temp - 25.0;
    final tempStatus = tempDiff > 0 ? '+${tempDiff.toStringAsFixed(1)}° above avg' : 'Normal';
    final humidityStatus = (hum >= 30 && hum <= 70) ? 'Comfortable' : (hum > 70 ? 'Humid' : 'Dry');

    return Row(
      children: [
        Expanded(
          child: _GlassStatCard(
            icon: Icons.thermostat,
            value: '${temp.toStringAsFixed(1)}°',
            subtitle: tempStatus,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _GlassStatCard(
            icon: Icons.water_drop,
            value: '${hum.toStringAsFixed(0)}%',
            subtitle: humidityStatus,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _GlassStatCard(
            icon: Icons.flash_on,
            value: energyValue,
            subtitle: energyLabel,
          ),
        ),
      ],
    );
  }
}

class _GlassStatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String subtitle;
  const _GlassStatCard({
    required this.icon,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return _LiquidGlassCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      borderRadius: BorderRadius.circular(24),
      child: Column(
        children: [
          Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ----- Quick Scenes Row -----
class _QuickScenesRow extends StatelessWidget {
  const _QuickScenesRow();

  @override
  Widget build(BuildContext context) {
    final scenes = ['Morning', 'Movie', 'Sleep', 'Party'];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: scenes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final scene = scenes[index];
          return GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$scene scene activated'), duration: const Duration(milliseconds: 800)),
              );
            },
            child: _LiquidGlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              borderRadius: BorderRadius.circular(40),
              child: Text(scene, style: const TextStyle(fontWeight: FontWeight.w500)),
            ),
          );
        },
      ),
    );
  }
}

// ----- Flame Sensor Card -----
class _FlameSensorCard extends StatelessWidget {
  final bool flame;
  const _FlameSensorCard({required this.flame});

  @override
  Widget build(BuildContext context) {
    return _LiquidGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      borderRadius: BorderRadius.circular(28),
      border: flame ? Border.all(color: Colors.red.withOpacity(0.6), width: 1.2) : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Flames Sensor', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7))),
              const SizedBox(height: 6),
              Text(
                flame ? '⚠️ FLAME DETECTED' : '✅ All Clear',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: flame ? Colors.red : Colors.green,
                ),
              ),
            ],
          ),
          Icon(flame ? Icons.local_fire_department : Icons.shield, size: 42, color: flame ? Colors.red : Colors.green),
        ],
      ),
    );
  }
}

// ----- Active Devices Row -----
class _ActiveDevicesRow extends StatelessWidget {
  final int activeCount;
  const _ActiveDevicesRow({required this.activeCount});

  @override
  Widget build(BuildContext context) {
    const totalDevices = 4;
    return _LiquidGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      borderRadius: BorderRadius.circular(28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Active', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          Text(
            '$activeCount / $totalDevices On',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ----- Rooms Selector -----
class _RoomsSelector extends StatelessWidget {
  final String selectedRoom;
  final ValueChanged<String> onRoomSelected;
  const _RoomsSelector({required this.selectedRoom, required this.onRoomSelected});

  @override
  Widget build(BuildContext context) {
    final rooms = ['Living Room', 'Bedroom', 'Kitchen', 'Bathroom'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Rooms', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final room = rooms[index];
              final isSelected = room == selectedRoom;
              return GestureDetector(
                onTap: () => onRoomSelected(room),
                child: _LiquidGlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  borderRadius: BorderRadius.circular(40),
                  border: isSelected ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
                  child: Text(
                    room,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Theme.of(context).colorScheme.primary : null,
                    ),
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

// ----- Room Details Panel -----
class _RoomDetailsPanel extends StatelessWidget {
  final String selectedRoom;
  final bool lightOn;
  final VoidCallback onLightToggle;
  final double ceilingBrightness;
  final ValueChanged<double> onCeilingBrightnessChanged;
  final double tvVolume;
  final ValueChanged<double> onTvVolumeChanged;

  const _RoomDetailsPanel({
    required this.selectedRoom,
    required this.lightOn,
    required this.onLightToggle,
    required this.ceilingBrightness,
    required this.onCeilingBrightnessChanged,
    required this.tvVolume,
    required this.onTvVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedRoom == 'Living Room') {
      return _LiquidGlassCard(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(selectedRoom, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(lightOn ? Icons.lightbulb : Icons.lightbulb_outline, color: lightOn ? Colors.amber : Colors.grey, size: 28),
                const SizedBox(width: 12),
                const Text('Ceiling Light', style: TextStyle(fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('${(ceilingBrightness * 100).toInt()}%', style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onLightToggle,
                  child: _LiquidGlassCard(
                    padding: const EdgeInsets.all(6),
                    borderRadius: BorderRadius.circular(30),
                    child: Icon(lightOn ? Icons.power_settings_new : Icons.power_off, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Slider(
              value: ceilingBrightness,
              onChanged: (val) => onCeilingBrightnessChanged(val),
              activeColor: Colors.amber,
              min: 0,
              max: 1,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Icon(Icons.tv, size: 28),
                const SizedBox(width: 12),
                const Text('Smart TV', style: TextStyle(fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('Vol ${(tvVolume * 100).toInt()}%', style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                _LiquidGlassCard(
                  padding: const EdgeInsets.all(6),
                  borderRadius: BorderRadius.circular(30),
                  child: const Icon(Icons.volume_up, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Slider(
              value: tvVolume,
              onChanged: (val) => onTvVolumeChanged(val),
              activeColor: Colors.blue,
              min: 0,
              max: 1,
            ),
          ],
        ),
      );
    } else {
      return _LiquidGlassCard(
        borderRadius: BorderRadius.circular(28),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(selectedRoom, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            Row(
              children: [
                Icon(lightOn ? Icons.lightbulb : Icons.lightbulb_outline, color: lightOn ? Colors.amber : Colors.grey),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onLightToggle,
                  child: _LiquidGlassCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    borderRadius: BorderRadius.circular(30),
                    child: Text(lightOn ? 'ON' : 'OFF', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
  }
}

// ============================================================
// 7. BOTTOM NAVIGATION BAR
// ============================================================
class _ModernBottomNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;
  const _ModernBottomNavBar({required this.selectedIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = [
      {'icon': Icons.home, 'label': 'Home'},
      {'icon': Icons.bolt, 'label': 'Energy'},
      {'icon': Icons.notifications, 'label': 'Alerts'},
      {'icon': Icons.settings, 'label': 'Settings'},
    ];
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black.withOpacity(0.7)
                : Colors.white.withOpacity(0.7),
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor.withOpacity(0.3)),
            ),
          ),
          child: SafeArea(
            child: SizedBox(
              height: 70,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (index) {
                  final isSelected = selectedIndex == index;
                  return GestureDetector(
                    onTap: () => onTap(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(40),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            items[index]['icon'] as IconData,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            items[index]['label'] as String,
                            style: TextStyle(
                              fontSize: 12,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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

// ============================================================
// 8. PLACEHOLDER SCREENS
// ============================================================
class _EnergyScreen extends StatelessWidget {
  const _EnergyScreen();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _LiquidGlassCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, size: 64, color: Colors.amber),
            const SizedBox(height: 16),
            const Text('Energy Consumption', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Today: 3.4 kWh', style: TextStyle(fontSize: 18)),
            const Text('This Week: 24.1 kWh'),
          ],
        ),
      ),
    );
  }
}

class _AlertsScreen extends StatelessWidget {
  const _AlertsScreen();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _LiquidGlassCard(
          child: const ListTile(
            leading: Icon(Icons.warning_amber, color: Colors.orange),
            title: Text('Motion detected in Living Room'),
            subtitle: Text('2 minutes ago'),
          ),
        ),
        const SizedBox(height: 12),
        _LiquidGlassCard(
          child: const ListTile(
            leading: Icon(Icons.local_fire_department, color: Colors.red),
            title: Text('Flame sensor test - All Clear'),
            subtitle: Text('1 hour ago'),
          ),
        ),
      ],
    );
  }
}

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
      padding: const EdgeInsets.all(20),
      children: [
        _LiquidGlassCard(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.brightness_6),
                title: const Text('Theme'),
                trailing: DropdownButton<ThemeMode>(
                  value: themeMode,
                  items: const [
                    DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                    DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                  ],
                  onChanged: (mode) => onThemeModeChanged(mode!),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Bluetooth Status'),
                trailing: bleStatus == BleStatus.connected
                    ? const Chip(label: Text('Connected'), backgroundColor: Colors.green)
                    : ElevatedButton(onPressed: onConnectBLE, child: const Text('Connect')),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Manual Refresh'),
                trailing: IconButton(onPressed: () => onRefresh(), icon: const Icon(Icons.sync)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// 9. LIQUID GLASS CARD
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

    final baseColor = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.white.withOpacity(0.7);

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
        filter: ui.ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur),
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
            gradient: gradient,
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
// 10. SKELETON LOADER
// ============================================================
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
      highlightColor: isDark ? Colors.grey.shade700 : Colors.grey.shade100,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _LiquidGlassCard(child: const SizedBox(height: 80)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _LiquidGlassCard(child: const SizedBox(height: 100))),
                const SizedBox(width: 16),
                Expanded(child: _LiquidGlassCard(child: const SizedBox(height: 100))),
                const SizedBox(width: 16),
                Expanded(child: _LiquidGlassCard(child: const SizedBox(height: 100))),
              ],
            ),
            const SizedBox(height: 16),
            _LiquidGlassCard(child: const SizedBox(height: 80)),
            const SizedBox(height: 16),
            _LiquidGlassCard(child: const SizedBox(height: 70)),
            const SizedBox(height: 16),
            _LiquidGlassCard(child: const SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}