import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';

// ============================================================
// 1. HTTP POLLING SERVICE (like original, but reactive with Riverpod)
// ============================================================
final databaseUrlProvider = Provider((ref) =>
'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app');

final smartHomeDataProvider = StreamProvider<Map<String, dynamic>>((ref) {
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
      // ignore errors silently, keep old data
    } finally {
      isFetching = false;
    }
  }

  // Start polling
  fetchData();
  timer = Timer.periodic(const Duration(seconds: 2), (_) => fetchData());

  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});

// Provider for toggling lights with optimistic update & haptic
final lightToggleProvider = Provider((ref) => LightToggleService(ref));

class LightToggleService {
  final Ref _ref;
  LightToggleService(this._ref);

  Future<void> toggle(String room, bool value, BuildContext context) async {
    final url = _ref.read(databaseUrlProvider);
    try {
      final response = await http.patch(
        Uri.parse('$url/smartHome/lights.json'),
        body: jsonEncode({room: value}),
      );
      if (response.statusCode == 200) {
        HapticFeedback.lightImpact();
        // No need to manually update UI – the poll will refresh in <2s,
        // but for instant feedback we can also update the local cache via ref.
        // However, the stream will auto-update on next poll.
      } else {
        throw Exception('Failed to toggle');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error toggling light: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

// ============================================================
// 2. MAIN DASHBOARD (ConsumerWidget)
// ============================================================
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(smartHomeDataProvider);

    Future<void> manualRefresh() async {
      // Force refetch by invalidating the provider (restarts stream)
      ref.invalidate(smartHomeDataProvider);
    }

    return Scaffold(
      appBar: _ModernAppBar(onRefresh: manualRefresh),
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
                onPressed: () => ref.invalidate(smartHomeDataProvider),
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
// 3. APP BAR
// ============================================================
class _ModernAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Future<void> Function() onRefresh;
  const _ModernAppBar({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: const Text('Smart Home', style: TextStyle(fontWeight: FontWeight.w600)),
      centerTitle: false,
      elevation: 0,
      actions: [
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
                const SnackBar(content: Text('Refreshed'), duration: Duration(seconds: 1)),
              );
            }
          },
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

// ============================================================
// 4. DASHBOARD CONTENT (same modern widgets as before)
// ============================================================
class _DashboardContent extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DashboardContent({required this.data});

  @override
  Widget build(BuildContext context) {
    final sensors = data['sensors'] as Map? ?? {};
    final lights = data['lights'] as Map? ?? {};
    final status = data['status'] as Map? ?? {};

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: _SensorCard(
              title: 'Temperature',
              value: '${(sensors['temperature'] ?? 0).toStringAsFixed(1)}°C',
              icon: Icons.thermostat,
              color: Colors.orange,
            )),
            const SizedBox(width: 16),
            Expanded(child: _SensorCard(
              title: 'Humidity',
              value: '${(sensors['humidity'] ?? 0).toStringAsFixed(1)}%',
              icon: Icons.water_drop,
              color: Colors.blue,
            )),
          ],
        ),
        const SizedBox(height: 16),
        _FlameCard(flame: sensors['flame'] == true),
        const SizedBox(height: 16),
        _LightsCard(
          room1: lights['room1'] == true,
          room2: lights['room2'] == true,
          room3: lights['room3'] == true,
        ),
        const SizedBox(height: 16),
        _StatusCard(online: status['online'] == true),
      ],
    );
  }
}

// ----- SENSOR CARD (glass morphism) -----
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Colors.grey.shade50],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: color),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
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

// ----- FLAME CARD with warning animation -----
class _FlameCard extends StatelessWidget {
  final bool flame;
  const _FlameCard({required this.flame});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: flame ? Colors.red.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: (flame ? Colors.red : Colors.grey).withOpacity(0.1),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: flame ? Border.all(color: Colors.red.shade200, width: 1.5) : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Flame Sensor', style: TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (flame) ...[
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    flame ? 'FLAME DETECTED!' : 'All Clear',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: flame ? Colors.red : Colors.green,
                    ),
                  ),
                ],
              ),
            ],
          ),
          CircleAvatar(
            radius: 32,
            backgroundColor: (flame ? Colors.red : Colors.green).withOpacity(0.1),
            child: Icon(
              flame ? Icons.local_fire_department : Icons.shield,
              color: flame ? Colors.red : Colors.green,
              size: 36,
            ),
          ),
        ],
      ),
    );
  }
}

// ----- LIGHTS CARD with toggle using Riverpod -----
class _LightsCard extends ConsumerWidget {
  final bool room1;
  final bool room2;
  final bool room3;

  const _LightsCard({
    required this.room1,
    required this.room2,
    required this.room3,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toggleService = ref.watch(lightToggleProvider);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Light Controls', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _LightSwitchTile(
            room: 'Room 1',
            value: room1,
            onChanged: (val) => toggleService.toggle('room1', val, context),
          ),
          const Divider(),
          _LightSwitchTile(
            room: 'Room 2',
            value: room2,
            onChanged: (val) => toggleService.toggle('room2', val, context),
          ),
          const Divider(),
          _LightSwitchTile(
            room: 'Room 3',
            value: room3,
            onChanged: (val) => toggleService.toggle('room3', val, context),
          ),
        ],
      ),
    );
  }
}

class _LightSwitchTile extends StatelessWidget {
  final String room;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _LightSwitchTile({required this.room, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(room, style: const TextStyle(fontWeight: FontWeight.w500)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.amber,
      secondary: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        child: Icon(
          value ? Icons.lightbulb : Icons.lightbulb_outline,
          color: value ? Colors.amber : Colors.grey,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}

// ----- STATUS CARD with pulsing dot -----
class _StatusCard extends StatelessWidget {
  final bool online;
  const _StatusCard({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
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
                  color: online ? Colors.green : Colors.red,
                  boxShadow: online ? [
                    BoxShadow(color: Colors.green.withOpacity(0.6), blurRadius: 8, spreadRadius: 2)
                  ] : [],
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
              color: online ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}

// ----- SKELETON LOADER (shimmer) -----
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.grey.shade300,
      highlightColor: Colors.grey.shade100,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: _buildSkeletonCard()),
              const SizedBox(width: 16),
              Expanded(child: _buildSkeletonCard()),
            ],
          ),
          const SizedBox(height: 16),
          _buildSkeletonCard(height: 100),
          const SizedBox(height: 16),
          _buildSkeletonCard(height: 220),
          const SizedBox(height: 16),
          _buildSkeletonCard(height: 70),
        ],
      ),
    );
  }

  Widget _buildSkeletonCard({double height = 120}) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
      ),
    );
  }
}