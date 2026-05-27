import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
// 1. Provider for Wi‑Fi scanning & connection
// ============================================================
final wifiSetupProvider = StateNotifierProvider<WifiSetupNotifier, WifiSetupState>((ref) {
  return WifiSetupNotifier();
});

class WifiSetupState {
  final List<WifiNetwork> networks;
  final bool isScanning;
  final bool isConnecting;
  final String? error;

  const WifiSetupState({
    this.networks = const [],
    this.isScanning = false,
    this.isConnecting = false,
    this.error = null,
  });

  WifiSetupState copyWith({
    List<WifiNetwork>? networks,
    bool? isScanning,
    bool? isConnecting,
    String? error,
  }) {
    return WifiSetupState(
      networks: networks ?? this.networks,
      isScanning: isScanning ?? this.isScanning,
      isConnecting: isConnecting ?? this.isConnecting,
      error: error ?? this.error,
    );
  }
}

class WifiSetupNotifier extends StateNotifier<WifiSetupState> {
  WifiSetupNotifier() : super(const WifiSetupState());

  // Request location permission (required for Wi‑Fi scanning on Android)
  Future<bool> _requestPermissions() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isDenied) {
      state = state.copyWith(error: 'Location permission is required to scan Wi‑Fi networks.');
      return false;
    }
    // Also ensure Wi‑Fi is enabled (optional)
    final isEnabled = await WiFiForIoTPlugin.isEnabled();
    if (!isEnabled) {
      await WiFiForIoTPlugin.setEnabled(true);
    }
    return true;
  }

  Future<void> scanNetworks() async {
    if (state.isScanning) return;
    state = state.copyWith(isScanning: true, error: null);

    final hasPermission = await _requestPermissions();
    if (!hasPermission) {
      state = state.copyWith(isScanning: false);
      return;
    }

    try {
      final list = await WiFiForIoTPlugin.loadWifiList();
      // Sort by signal strength (higher level = stronger)
      list.sort((a, b) => (b.level ?? -100).compareTo(a.level ?? -100));
      state = state.copyWith(networks: list, isScanning: false);
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: 'Failed to scan: $e',
      );
    }
  }

  Future<void> connectToNetwork(String ssid, String password, BuildContext context) async {
    if (ssid.isEmpty) {
      _showSnackbar(context, 'SSID cannot be empty', Colors.red);
      return;
    }
    if (password.isEmpty) {
      _showSnackbar(context, 'Please enter the Wi‑Fi password', Colors.red);
      return;
    }
    if (state.isConnecting) return;

    state = state.copyWith(isConnecting: true, error: null);
    try {
      final success = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        security: NetworkSecurity.WPA,
        joinOnce: true,
      ).timeout(const Duration(seconds: 15));
      if (success) {
        _showSnackbar(context, 'Connected to $ssid', Colors.green);
        if (context.mounted) Navigator.pop(context);
      } else {
        throw Exception('Connection failed');
      }
    } catch (e) {
      state = state.copyWith(error: 'Connection error: $e');
      _showSnackbar(context, state.error!, Colors.red);
    } finally {
      state = state.copyWith(isConnecting: false);
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
// 2. Main UI (ConsumerStatefulWidget to manage password field)
// ============================================================
class WifiSetupPage extends ConsumerStatefulWidget {
  const WifiSetupPage({super.key});

  @override
  ConsumerState<WifiSetupPage> createState() => _WifiSetupPageState();
}

class _WifiSetupPageState extends ConsumerState<WifiSetupPage> {
  final TextEditingController _passwordController = TextEditingController();
  String? _selectedSsid;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(wifiSetupProvider.notifier).scanNetworks());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wifiSetupProvider);
    final notifier = ref.read(wifiSetupProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi‑Fi Setup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isScanning ? null : () => notifier.scanNetworks(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Wi‑Fi Password',
                prefixIcon: Icon(Icons.lock),
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              enabled: !state.isConnecting,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _buildNetworkList(state, notifier),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkList(WifiSetupState state, WifiSetupNotifier notifier) {
    if (state.isScanning) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.networks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(state.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => notifier.scanNetworks(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (state.networks.isEmpty) {
      return const Center(child: Text('No Wi‑Fi networks found. Pull down to refresh.'));
    }

    return RefreshIndicator(
      onRefresh: () => notifier.scanNetworks(),
      child: ListView.builder(
        itemCount: state.networks.length,
        itemBuilder: (context, index) {
          final wifi = state.networks[index];
          final ssid = wifi.ssid ?? 'Unknown';
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: Icon(_signalIcon(wifi.level ?? -100)),  // ✅ FIXED: wrapped in Icon()
              title: Text(ssid),
              trailing: _selectedSsid == ssid && state.isConnecting
                  ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : null,
              onTap: state.isConnecting
                  ? null
                  : () {
                setState(() => _selectedSsid = ssid);
                notifier.connectToNetwork(ssid, _passwordController.text, context);
              },
            ),
          );
        },
      ),
    );
  }

  IconData _signalIcon(int level) {
    if (level >= -50) return Icons.signal_wifi_4_bar;
    if (level >= -60) return Icons.signal_wifi_0_bar;
    if (level >= -70) return Icons.signal_wifi_0_bar;
    if (level >= -80) return Icons.signal_wifi_0_bar;
    return Icons.signal_wifi_0_bar;
  }
}