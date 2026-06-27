import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

// ============================================================
// 1. Provider for the database URL
// ============================================================
final databaseUrlProvider = Provider((ref) =>
'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app');

// ============================================================
// 2. StateNotifier for Wi‑Fi scanning & sending
// ============================================================
final wifiConfigProvider = StateNotifierProvider<WifiConfigNotifier, WifiConfigState>((ref) {
  return WifiConfigNotifier(ref);
});

class WifiConfigState {
  final List<WiFiAccessPoint> accessPoints;
  final bool isScanning;
  final bool isSending;
  final String? error;

  const WifiConfigState({
    this.accessPoints = const [],
    this.isScanning = false,
    this.isSending = false,
    this.error = null,
  });

  WifiConfigState copyWith({
    List<WiFiAccessPoint>? accessPoints,
    bool? isScanning,
    bool? isSending,
    String? error,
  }) {
    return WifiConfigState(
      accessPoints: accessPoints ?? this.accessPoints,
      isScanning: isScanning ?? this.isScanning,
      isSending: isSending ?? this.isSending,
      error: error ?? this.error,
    );
  }
}

class WifiConfigNotifier extends StateNotifier<WifiConfigState> {
  final Ref _ref;
  WifiConfigNotifier(this._ref) : super(const WifiConfigState());

  Future<bool> _canScan() async {
    final can = await WiFiScan.instance.canGetScannedResults();
    if (can != CanGetScannedResults.yes) {
      final status = await Permission.locationWhenInUse.request();
      if (status.isDenied) return false;
      await Permission.location.request();
      return await WiFiScan.instance.canGetScannedResults() == CanGetScannedResults.yes;
    }
    return true;
  }

  Future<void> scanNetworks() async {
    if (state.isScanning) return;
    state = state.copyWith(isScanning: true, error: null);

    final can = await _canScan();
    if (!can) {
      state = state.copyWith(
        isScanning: false,
        error: 'Cannot scan Wi‑Fi. Please enable Location services and grant permission.',
      );
      return;
    }

    try {
      final results = await WiFiScan.instance.getScannedResults();
      results.sort((a, b) => b.level.compareTo(a.level));
      state = state.copyWith(accessPoints: results, isScanning: false);
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: 'Scan failed: $e',
      );
    }
  }

  Future<void> sendCredentials(String ssid, String password, BuildContext context) async {
    if (ssid.trim().isEmpty) {
      _showSnack(context, 'Please enter an SSID', _DT.red);
      return;
    }
    if (state.isSending) return;

    state = state.copyWith(isSending: true, error: null);
    final url = _ref.read(databaseUrlProvider);

    try {
      final response = await http.patch(
        Uri.parse('$url/wifiConfig.json'),
        body: jsonEncode({'ssid': ssid.trim(), 'password': password.trim()}),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        _showSnack(context, 'Credentials sent. ESP32 will reconnect.', _DT.green);
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      state = state.copyWith(error: 'Failed to send: $e');
      _showSnack(context, state.error!, _DT.red);
    } finally {
      state = state.copyWith(isSending: false);
    }
  }

  Future<void> forgetNetwork(BuildContext context) async {
    if (state.isSending) return;
    state = state.copyWith(isSending: true);
    final url = _ref.read(databaseUrlProvider);

    try {
      final response = await http.patch(
        Uri.parse('$url/wifiConfig.json'),
        body: jsonEncode({'command': 'forget'}),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        _showSnack(context, 'Forget command sent. ESP32 will reboot into AP mode.', _DT.amber);
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      _showSnack(context, 'Forget failed: $e', _DT.red);
    } finally {
      state = state.copyWith(isSending: false);
    }
  }
}

// ============================================================
// 3. Design tokens and widgets (same as dashboard)
// ============================================================
class _DT {
  static const purple = Color(0xFF6C63FF);
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = Color(0xFF64B5F6);
  static const red = Color(0xFFFF5252);
  static const espConnected = Color(0xFF4DFFA0);
}

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

void _showSnack(BuildContext context, String msg, Color red, {Color color = Colors.white}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: color.withValues(alpha: 0.9),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    margin: const EdgeInsets.all(16),
    duration: const Duration(seconds: 2),
  ));
}

class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final IconData actionIcon;
  final VoidCallback? onAction;

  const _GlassAppBar({
    required this.title,
    required this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AppBar(
          title: Text(title),
          backgroundColor: isDark
              ? Colors.black.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.3),
          elevation: 0,
          actions: [
            if (onAction != null)
              IconButton(
                icon: Icon(actionIcon, color: Theme.of(context).colorScheme.onSurface),
                onPressed: onAction,
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
// 4. Main UI Widget (Redesigned)
// ============================================================
class WifiConfigPage extends ConsumerStatefulWidget {
  const WifiConfigPage({super.key});

  @override
  ConsumerState<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends ConsumerState<WifiConfigPage> {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(wifiConfigProvider.notifier).scanNetworks());
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configState = ref.watch(wifiConfigProvider);
    final notifier = ref.read(wifiConfigProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _GlassAppBar(
        title: 'WiFi Settings (Online)',
        actionIcon: Icons.refresh,
        onAction: configState.isScanning ? null : () => notifier.scanNetworks(),
      ),
      body: _WallpaperBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _ssidController,
                      decoration: const InputDecoration(
                        labelText: 'SSID',
                        prefixIcon: Icon(Icons.wifi),
                        border: OutlineInputBorder(),
                      ),
                      enabled: !configState.isSending,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.lock),
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                      enabled: !configState.isSending,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: configState.isSending ? null : () => notifier.sendCredentials(
                        _ssidController.text,
                        _passwordController.text,
                        context,
                      ),
                      icon: configState.isSending
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send),
                      label: const Text('Send to ESP32'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: configState.isSending ? null : () => notifier.forgetNetwork(context),
                      icon: const Icon(Icons.delete_forever, color: _DT.red),
                      label: const Text('Forget Network & Reboot to AP', style: TextStyle(color: _DT.red)),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _GCard(
                padding: const EdgeInsets.all(16),
                child: _NetworkList(
                  accessPoints: configState.accessPoints,
                  isScanning: configState.isScanning,
                  error: configState.error,
                  onTapNetwork: (ssid) => _ssidController.text = ssid,
                  onRefresh: () => notifier.scanNetworks(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 5. Network List Widget
// ============================================================
class _NetworkList extends StatelessWidget {
  final List<WiFiAccessPoint> accessPoints;
  final bool isScanning;
  final String? error;
  final void Function(String ssid) onTapNetwork;
  final VoidCallback onRefresh;

  const _NetworkList({
    required this.accessPoints,
    required this.isScanning,
    required this.error,
    required this.onTapNetwork,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (isScanning) {
      return const Center(child: CircularProgressIndicator(color: _DT.purple));
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: _DT.red.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: _DT.red)),
            const SizedBox(height: 12),
            _PillBtn(label: 'Retry', onTap: onRefresh),
          ],
        ),
      );
    }
    if (accessPoints.isEmpty) {
      return const Center(child: Text('No Wi‑Fi networks found. Tap refresh to scan.'));
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        itemCount: accessPoints.length,
        itemBuilder: (context, index) {
          final ap = accessPoints[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _GCard(
              padding: const EdgeInsets.all(12),
              child: ListTile(
                leading: Icon(_signalIcon(ap.level), color: _DT.purple),
                title: Text(ap.ssid, style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${ap.level} dBm', style: const TextStyle(color: Colors.grey)),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
                  ],
                ),
                onTap: () => onTapNetwork(ap.ssid),
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -50) return Icons.signal_wifi_4_bar;
    if (rssi >= -60) return Icons.signal_wifi_0_bar;
    if (rssi >= -70) return Icons.signal_wifi_0_bar;
    if (rssi >= -80) return Icons.signal_wifi_0_bar;
    return Icons.signal_wifi_0_bar;
  }
}

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