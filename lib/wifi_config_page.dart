import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
// 1. Provider for the database URL (shared)
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

  // Check if we can scan (permissions + location)
  Future<bool> _canScan() async {
    final can = await WiFiScan.instance.canGetScannedResults();
    if (can != CanGetScannedResults.yes) {
      // Request permissions if not granted
      final status = await Permission.locationWhenInUse.request();
      if (status.isDenied) return false;
      // Also need to request `ACCESS_FINE_LOCATION` for Android
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
      // Sort by signal strength (strongest first)
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
      _showSnackbar(context, 'Please enter an SSID', Colors.red);
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
        _showSnackbar(context, 'Credentials sent. ESP32 will reconnect.', Colors.green);
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      state = state.copyWith(error: 'Failed to send: $e');
      _showSnackbar(context, state.error!, Colors.red);
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
        _showSnackbar(context, 'Forget command sent. ESP32 will reboot into AP mode.', Colors.orange);
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      _showSnackbar(context, 'Forget failed: $e', Colors.red);
    } finally {
      state = state.copyWith(isSending: false);
    }
  }

  void _showSnackbar(BuildContext context, String message, Color color) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: color),
      );
    }
  }
}

// ============================================================
// 3. Main UI Widget (ConsumerStatefulWidget for controllers)
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
    // Auto‑scan when page loads
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
      appBar: AppBar(
        title: const Text('WiFi Settings (Online)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: configState.isScanning ? null : () => notifier.scanNetworks(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InputSection(
              ssidController: _ssidController,
              passwordController: _passwordController,
              isSending: configState.isSending,
              onSend: () => notifier.sendCredentials(
                _ssidController.text,
                _passwordController.text,
                context,
              ),
              onForget: () => notifier.forgetNetwork(context),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            _NetworkList(
              accessPoints: configState.accessPoints,
              isScanning: configState.isScanning,
              error: configState.error,
              onTapNetwork: (ssid) => _ssidController.text = ssid,
              onRefresh: () => notifier.scanNetworks(),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 4. Input Section Widget
// ============================================================
class _InputSection extends StatelessWidget {
  final TextEditingController ssidController;
  final TextEditingController passwordController;
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onForget;

  const _InputSection({
    required this.ssidController,
    required this.passwordController,
    required this.isSending,
    required this.onSend,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: ssidController,
          decoration: const InputDecoration(
            labelText: 'SSID',
            prefixIcon: Icon(Icons.wifi),
            border: OutlineInputBorder(),
          ),
          enabled: !isSending,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            prefixIcon: Icon(Icons.lock),
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          enabled: !isSending,
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: isSending ? null : onSend,
          icon: isSending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
          label: const Text('Send to ESP32'),
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: isSending ? null : onForget,
          icon: const Icon(Icons.delete_forever, color: Colors.red),
          label: const Text('Forget Network & Reboot to AP'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        ),
      ],
    );
  }
}

// ============================================================
// 5. Network List Widget (with refresh & error handling)
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
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 8),
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: onRefresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (accessPoints.isEmpty) {
      return const Center(child: Text('No Wi‑Fi networks found. Tap refresh to scan.'));
    }
    return Expanded(
      child: RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: ListView.builder(
          itemCount: accessPoints.length,
          itemBuilder: (context, index) {
            final ap = accessPoints[index];
            return ListTile(
              leading: Icon(_signalIcon(ap.level)),
              title: Text(ap.ssid),
              trailing: Text('${ap.level} dBm'),
              onTap: () => onTapNetwork(ap.ssid),
            );
          },
        ),
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