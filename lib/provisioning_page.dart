import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

// ============================================================
// 1. Providers for scanning and sending credentials
// ============================================================
final provisionProvider = StateNotifierProvider<ProvisionNotifier, ProvisionState>((ref) {
  return ProvisionNotifier();
});

enum ProvisionStatus { initial, loading, success, error }

class ProvisionState {
  final ProvisionStatus status;
  final List<WifiNetwork> networks;
  final String? errorMessage;

  ProvisionState({
    this.status = ProvisionStatus.initial,
    this.networks = const [],
    this.errorMessage,
  });

  ProvisionState copyWith({
    ProvisionStatus? status,
    List<WifiNetwork>? networks,
    String? errorMessage,
  }) {
    return ProvisionState(
      status: status ?? this.status,
      networks: networks ?? this.networks,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class WifiNetwork {
  final String ssid;
  final int rssi;
  final bool isOpen;

  WifiNetwork({required this.ssid, required this.rssi, required this.isOpen});

  factory WifiNetwork.fromJson(Map<String, dynamic> json) {
    return WifiNetwork(
      ssid: json['ssid'] as String,
      rssi: json['rssi'] as int,
      isOpen: json['encryption'] == 'open',
    );
  }
}

class ProvisionNotifier extends StateNotifier<ProvisionState> {
  ProvisionNotifier() : super(ProvisionState());

  // Cancel any ongoing operation
  Future<void> scanNetworks() async {
    if (state.status == ProvisionStatus.loading) return;
    state = state.copyWith(status: ProvisionStatus.loading, errorMessage: null);

    try {
      final response = await http
          .get(Uri.parse('http://192.168.4.1/scan'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> networksJson = data['networks'] ?? [];
        final networks = networksJson
            .map((json) => WifiNetwork.fromJson(json))
            .toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi)); // sort by signal strength
        state = state.copyWith(status: ProvisionStatus.success, networks: networks);
      } else {
        state = state.copyWith(
          status: ProvisionStatus.error,
          errorMessage: 'Scan failed (HTTP ${response.statusCode})',
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: ProvisionStatus.error,
        errorMessage: 'Cannot reach ESP32.\n'
            'Make sure you are connected to the "ESP32_Config" Wi‑Fi network.',
      );
    }
  }

  Future<void> sendCredentials(String ssid, String password, BuildContext context) async {
    if (state.status == ProvisionStatus.loading) return;
    state = state.copyWith(status: ProvisionStatus.loading, errorMessage: null);

    try {
      final response = await http
          .post(
        Uri.parse('http://192.168.4.1/save'),
        body: {'ssid': ssid, 'pass': password},
      )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        state = state.copyWith(status: ProvisionStatus.success);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Credentials sent. ESP32 will now reboot.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        state = state.copyWith(
          status: ProvisionStatus.error,
          errorMessage: 'Save failed (HTTP ${response.statusCode})',
        );
        _showErrorSnackbar(context);
      }
    } catch (e) {
      state = state.copyWith(
        status: ProvisionStatus.error,
        errorMessage: 'Error: $e',
      );
      _showErrorSnackbar(context);
    }
  }

  void _showErrorSnackbar(BuildContext context) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.errorMessage ?? 'Unknown error'), backgroundColor: Colors.red),
      );
    }
  }

  void reset() {
    state = ProvisionState();
  }
}

// ============================================================
// 2. UI Widget
// ============================================================
class ProvisionPage extends ConsumerStatefulWidget {
  const ProvisionPage({super.key});

  @override
  ConsumerState<ProvisionPage> createState() => _ProvisionPageState();
}

class _ProvisionPageState extends ConsumerState<ProvisionPage> {
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(provisionProvider.notifier).scanNetworks());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    ref.read(provisionProvider.notifier).reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provisionState = ref.watch(provisionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Provision ESP32'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: provisionState.status == ProvisionStatus.loading
                ? null
                : () => ref.read(provisionProvider.notifier).scanNetworks(),
          ),
        ],
      ),
      body: _buildBody(provisionState),
    );
  }

  Widget _buildBody(ProvisionState state) {
    if (state.status == ProvisionStatus.loading && state.networks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == ProvisionStatus.error && state.networks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off, size: 64, color: Colors.red.shade300),
              const SizedBox(height: 16),
              Text(state.errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => ref.read(provisionProvider.notifier).scanNetworks(),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.networks.isEmpty) {
      return const Center(child: Text('No Wi‑Fi networks found'));
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(provisionProvider.notifier).scanNetworks(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: state.networks.length,
        itemBuilder: (context, index) {
          final net = state.networks[index];
          return _NetworkTile(
            network: net,
            onTap: () => _showPasswordDialog(net.ssid),
            isSending: state.status == ProvisionStatus.loading,
          );
        },
      ),
    );
  }

  void _showPasswordDialog(String ssid) {
    _passwordController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Connect to $ssid'),
        content: TextField(
          controller: _passwordController,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final password = _passwordController.text.trim();
              if (password.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Please enter password')),
                );
                return;
              }
              Navigator.pop(ctx);
              ref.read(provisionProvider.notifier).sendCredentials(ssid, password, context);
            },
            icon: const Icon(Icons.send),
            label: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 3. Network Tile Widget (with signal strength icon)
// ============================================================
class _NetworkTile extends StatelessWidget {
  final WifiNetwork network;
  final VoidCallback onTap;
  final bool isSending;

  const _NetworkTile({
    required this.network,
    required this.onTap,
    required this.isSending,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        network.isOpen ? Icons.lock_open : Icons.lock,
        color: network.isOpen ? Colors.green : Colors.orange,
      ),
      title: Text(
        network.ssid,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Row(
        children: [
          Icon(_getSignalIcon(network.rssi), size: 16, color: Colors.grey),
          const SizedBox(width: 4),
          Text('${network.rssi} dBm'),
          const SizedBox(width: 12),
          if (!network.isOpen) const Text('Secured', style: TextStyle(fontSize: 12)),
        ],
      ),
      trailing: isSending
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: isSending ? null : onTap,
    );
  }

  IconData _getSignalIcon(int rssi) {
    if (rssi >= -50) return Icons.signal_wifi_4_bar;
    if (rssi >= -60) return Icons.signal_wifi_0_bar;
    if (rssi >= -70) return Icons.signal_wifi_0_bar;
    if (rssi >= -80) return Icons.signal_wifi_0_bar;
    return Icons.signal_wifi_0_bar;
  }
}