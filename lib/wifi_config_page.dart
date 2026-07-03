import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'ble_service.dart';

class EspWifiNetwork {
  final String ssid;
  final int rssi;
  final int? channel;
  final String encryption;
  final bool secure;
  final bool current;

  const EspWifiNetwork({
    required this.ssid,
    required this.rssi,
    this.channel,
    required this.encryption,
    required this.secure,
    required this.current,
  });

  factory EspWifiNetwork.fromMap(Map<String, dynamic> map) {
    final enc = (map['encryption'] ?? '').toString();
    final secureValue = map['secure'];
    return EspWifiNetwork(
      ssid: (map['ssid'] ?? '').toString(),
      rssi: (map['rssi'] is num) ? (map['rssi'] as num).toInt() : -100,
      channel: map['channel'] is num ? (map['channel'] as num).toInt() : null,
      encryption: enc.isEmpty ? 'secured' : enc,
      secure: secureValue is bool ? secureValue : enc.toLowerCase() != 'open',
      current: map['current'] == true,
    );
  }
}

class EspWifiStatus {
  final bool online;
  final String ssid;
  final String ip;
  final String gateway;
  final int rssi;
  final String uniqueCode;
  final String source;

  const EspWifiStatus({
    required this.online,
    required this.ssid,
    required this.ip,
    required this.gateway,
    required this.rssi,
    required this.uniqueCode,
    required this.source,
  });

  factory EspWifiStatus.fromMap(Map<String, dynamic> map, String source) {
    return EspWifiStatus(
      online: map['online'] == true || map['wifiConnected'] == true || (map['ip'] ?? '').toString().isNotEmpty,
      ssid: (map['ssid'] ?? '').toString(),
      ip: (map['ip'] ?? '').toString(),
      gateway: (map['gateway'] ?? '').toString(),
      rssi: map['rssi'] is num ? (map['rssi'] as num).toInt() : 0,
      uniqueCode: (map['uniqueCode'] ?? '').toString(),
      source: source,
    );
  }
}

class WifiConfigPage extends ConsumerStatefulWidget {
  const WifiConfigPage({super.key});

  @override
  ConsumerState<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends ConsumerState<WifiConfigPage> {
  final TextEditingController _manualSsidController = TextEditingController();
  StreamSubscription<BleStatus>? _bleSub;

  EspWifiStatus? _status;
  List<EspWifiNetwork> _networks = const [];
  bool _loadingStatus = true;
  bool _scanning = false;
  bool _busy = false;
  String? _error;
  String? _lastIp;

  @override
  void initState() {
    super.initState();
    _bleSub = ref.read(bleServiceProvider).statusStream.listen((_) {
      if (mounted) setState(() {});
    });
    Future.microtask(_loadStatus);
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _manualSsidController.dispose();
    super.dispose();
  }

  bool get _bleReady => ref.read(bleServiceProvider).isConnected;

  Future<String?> _lookupEspIp() async {
    if (_lastIp != null && _lastIp!.isNotEmpty) return _lastIp;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final codeResponse = await http
        .get(Uri.parse('${AppConfig.databaseUrl}/users/${user.uid}/esp32Code.json'))
        .timeout(AppConfig.mediumTimeout);
    if (codeResponse.statusCode != 200 || codeResponse.body == 'null') return null;
    final code = (jsonDecode(codeResponse.body) ?? '').toString();
    if (code.isEmpty) return null;

    final statusResponse = await http
        .get(Uri.parse('${AppConfig.databaseUrl}/esp_public/$code/status.json'))
        .timeout(AppConfig.mediumTimeout);
    if (statusResponse.statusCode != 200 || statusResponse.body == 'null') return null;
    final decoded = jsonDecode(statusResponse.body);
    if (decoded is Map && decoded['ip'] != null) {
      _lastIp = decoded['ip'].toString();
      return _lastIp;
    }
    return null;
  }

  Future<Map<String, dynamic>> _localGetJson(String path, {Duration? timeout}) async {
    final ip = await _lookupEspIp();
    if (ip == null || ip.isEmpty) {
      throw Exception('ESP32 IP is unavailable. Connect Bluetooth backup or make sure the phone has internet to read the ESP status.');
    }
    final response = await http
        .get(Uri.parse('http://$ip$path'), headers: const {'Cache-Control': 'no-cache'})
        .timeout(timeout ?? AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 response');
    return decoded.cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _localPostJson(String path, Map<String, dynamic> body) async {
    final ip = await _lookupEspIp();
    if (ip == null || ip.isEmpty) {
      throw Exception('ESP32 IP is unavailable. Use Bluetooth backup or connect to the same Wi-Fi as the ESP32.');
    }
    final response = await http
        .post(
      Uri.parse('http://$ip$path'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    )
        .timeout(AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 returned HTTP ${response.statusCode}: ${response.body}');
    }
    final decoded = response.body.trim().isEmpty ? <String, dynamic>{'success': true} : jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 response');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _loadStatus() async {
    if (!mounted) return;
    setState(() {
      _loadingStatus = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final data = await ble.sendCommand({'cmd': 'wifi_status'}, timeout: const Duration(seconds: 4));
        if (!mounted) return;
        setState(() {
          _status = EspWifiStatus.fromMap(data, 'Bluetooth');
          _loadingStatus = false;
        });
        return;
      }

      final data = await _localGetJson('/api/wifi/status', timeout: AppConfig.mediumTimeout);
      if (!mounted) return;
      setState(() {
        _status = EspWifiStatus.fromMap(data, 'Local Wi-Fi');
        _loadingStatus = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingStatus = false;
        _error = 'Could not read ESP32 Wi-Fi status. Connect Bluetooth backup, or make sure your phone can reach the ESP32 local IP.\n\n$e';
      });
    }
  }

  Future<void> _scanNetworks() async {
    if (_scanning) return;
    HapticFeedback.selectionClick();
    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      List<Map<String, dynamic>> raw;
      String source;
      if (ble.isConnected) {
        raw = await ble.scanWifi();
        source = 'Bluetooth';
        await _loadStatus();
      } else {
        final data = await _localGetJson('/api/wifi/scan', timeout: const Duration(seconds: 18));
        final rawList = data['networks'];
        raw = rawList is List ? rawList.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];
        source = 'Local Wi-Fi';
        if (data['connected'] is Map) {
          _status = EspWifiStatus.fromMap((data['connected'] as Map).cast<String, dynamic>(), source);
        }
      }

      final networks = raw
          .map(EspWifiNetwork.fromMap)
          .where((n) => n.ssid.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      if (!mounted) return;
      setState(() {
        _networks = networks;
        _scanning = false;
        if (networks.isEmpty) {
          _error = 'ESP32 scan completed, but no nearby networks were returned. Try again closer to the router.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = 'ESP32 Wi-Fi scan failed. Use Bluetooth backup if the phone is not on the same network as the ESP32.\n\n$e';
      });
    }
  }

  Future<void> _connectToNetwork(String ssid, String password) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.connectWifi(ssid, password);
        if (!ok) throw Exception('ESP32 rejected the Bluetooth Wi-Fi command');
      } else {
        await _localPostJson('/api/wifi/connect', {'ssid': ssid, 'password': password, 'pass': password});
      }
      if (!mounted) return;
      _showSnack(context, 'Wi-Fi saved. ESP32 will restart and reconnect.', _DT.green);
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to save Wi-Fi credentials.\n\n$e';
      });
      _showSnack(context, 'Wi-Fi change failed', _DT.red);
    }
  }

  Future<void> _forgetNetwork() async {
    final confirm = await _showConfirmDialog(
      context,
      title: 'Forget ESP32 Wi-Fi?',
      message: 'The ESP32 will clear saved Wi-Fi credentials and restart into setup mode.',
      confirmText: 'Forget',
      danger: true,
    );
    if (confirm != true || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.forgetWifi();
        if (!ok) throw Exception('ESP32 rejected the Bluetooth forget command');
      } else {
        await _localPostJson('/api/wifi/forget', <String, dynamic>{});
      }
      if (!mounted) return;
      _showSnack(context, 'Wi-Fi forgotten. ESP32 is restarting into setup mode.', _DT.amber);
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Forget network failed. Connect Bluetooth backup or use the ESP32_Config setup mode.\n\n$e';
      });
    }
  }

  Future<void> _openConnectSheet({EspWifiNetwork? network}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _WifiConnectSheet(
        initialSsid: network?.ssid ?? _manualSsidController.text,
        secure: network?.secure ?? true,
        busy: _busy,
        onConnect: (ssid, password) async {
          Navigator.pop(sheetContext);
          await _connectToNetwork(ssid, password);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = ref.watch(bleServiceProvider);
    final bleConnected = ble.isConnected;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _GlassAppBar(
        title: 'ESP32 Wi-Fi Manager',
        actionIcon: Icons.refresh_rounded,
        onAction: _loadingStatus ? null : _loadStatus,
      ),
      body: _WallpaperBackground(
        child: SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: () async {
              await _loadStatus();
              await _scanNetworks();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              children: [
                const SizedBox(height: kToolbarHeight + 8),
                _CurrentNetworkCard(
                  status: _status,
                  loading: _loadingStatus,
                  bleConnected: bleConnected,
                  busy: _busy,
                  onForget: _forgetNetwork,
                  onConnectBle: () => ref.read(bleServiceProvider).connect(),
                ),
                const SizedBox(height: 16),
                _GCard(
                  padding: const EdgeInsets.all(16),
                  glowColor: _DT.blue,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              color: _DT.blue.withValues(alpha: 0.15),
                            ),
                            child: const Icon(Icons.radar_rounded, color: _DT.blue),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Nearby networks from ESP32', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                SizedBox(height: 4),
                                Text('The ESP scans with its own antenna, not the phone.', style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _PrimaryButton(
                              label: _scanning ? 'Scanning...' : 'Scan nearby networks',
                              icon: Icons.wifi_find_rounded,
                              busy: _scanning,
                              onTap: _scanning ? null : _scanNetworks,
                            ),
                          ),
                          const SizedBox(width: 10),
                          _IconGlassButton(
                            icon: Icons.edit_rounded,
                            tooltip: 'Manual SSID',
                            onTap: () => _openConnectSheet(),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _InlineError(message: _error!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_networks.isEmpty && !_scanning)
                  _EmptyNetworksCard(onScan: _scanNetworks)
                else
                  ..._networks.map((network) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NetworkTile(
                      network: network,
                      onTap: () => _openConnectSheet(network: network),
                    ),
                  )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WifiConnectSheet extends StatefulWidget {
  final String initialSsid;
  final bool secure;
  final bool busy;
  final Future<void> Function(String ssid, String password) onConnect;

  const _WifiConnectSheet({
    required this.initialSsid,
    required this.secure,
    required this.busy,
    required this.onConnect,
  });

  @override
  State<_WifiConnectSheet> createState() => _WifiConnectSheetState();
}

class _WifiConnectSheetState extends State<_WifiConnectSheet> {
  late final TextEditingController _ssidController;
  final TextEditingController _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _ssidController = TextEditingController(text: widget.initialSsid);
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: _GCard(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Connect ESP32 to Wi-Fi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              const Text('Enter the password for this network. The ESP32 will restart after saving.', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 18),
              TextField(
                controller: _ssidController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'SSID',
                  prefixIcon: const Icon(Icons.wifi_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => widget.onConnect(_ssidController.text.trim(), _passwordController.text),
                decoration: InputDecoration(
                  labelText: widget.secure ? 'Password' : 'Password (optional)',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 18),
              _PrimaryButton(
                label: 'Save and reconnect ESP32',
                icon: Icons.check_rounded,
                onTap: () => widget.onConnect(_ssidController.text.trim(), _passwordController.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentNetworkCard extends StatelessWidget {
  final EspWifiStatus? status;
  final bool loading;
  final bool bleConnected;
  final bool busy;
  final VoidCallback onForget;
  final VoidCallback onConnectBle;

  const _CurrentNetworkCard({
    required this.status,
    required this.loading,
    required this.bleConnected,
    required this.busy,
    required this.onForget,
    required this.onConnectBle,
  });

  @override
  Widget build(BuildContext context) {
    final connected = status?.online == true;
    return _GCard(
      padding: const EdgeInsets.all(18),
      glowColor: connected ? _DT.green : _DT.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: (connected ? _DT.green : _DT.amber).withValues(alpha: 0.15),
                ),
                child: Icon(connected ? Icons.wifi_rounded : Icons.wifi_off_rounded, color: connected ? _DT.green : _DT.amber),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loading ? 'Reading ESP32 Wi-Fi...' : (connected ? 'ESP32 is connected' : 'ESP32 Wi-Fi unavailable'),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(
                      status?.ssid.isNotEmpty == true ? status!.ssid : 'No network name available',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.58)),
                    ),
                  ],
                ),
              ),
              if (loading) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(icon: Icons.route_rounded, text: bleConnected ? 'Bluetooth ready' : (status?.source ?? 'No path')),
              if (status?.ip.isNotEmpty == true) _InfoChip(icon: Icons.lan_rounded, text: status!.ip),
              if (status != null) _InfoChip(icon: Icons.signal_wifi_4_bar_rounded, text: '${status!.rssi} dBm'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SecondaryButton(
                  label: bleConnected ? 'Bluetooth connected' : 'Connect Bluetooth backup',
                  icon: Icons.bluetooth_rounded,
                  onTap: bleConnected ? null : onConnectBle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DangerButton(
                  label: busy ? 'Working...' : 'Forget Wi-Fi',
                  icon: Icons.delete_outline_rounded,
                  onTap: busy ? null : onForget,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NetworkTile extends StatelessWidget {
  final EspWifiNetwork network;
  final VoidCallback onTap;

  const _NetworkTile({required this.network, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(12),
      glowColor: network.current ? _DT.green : null,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _signalColor(network.rssi).withValues(alpha: 0.16),
          ),
          child: Icon(_signalIcon(network.rssi), color: _signalColor(network.rssi)),
        ),
        title: Text(network.ssid, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text('${network.encryption} • ${network.rssi} dBm${network.channel == null ? '' : ' • CH ${network.channel}'}'),
        trailing: network.current
            ? const _MiniBadge(label: 'Current', color: _DT.green)
            : Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35)),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyNetworksCard extends StatelessWidget {
  final VoidCallback onScan;
  const _EmptyNetworksCard({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(Icons.wifi_find_rounded, size: 56, color: _DT.purple.withValues(alpha: 0.85)),
          const SizedBox(height: 12),
          const Text('No scanned networks yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text('Tap scan to let the ESP32 search for nearby Wi-Fi networks.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 18),
          _PrimaryButton(label: 'Scan now', icon: Icons.radar_rounded, onTap: onScan),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  const _InlineError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _DT.red.withValues(alpha: 0.11),
        border: Border.all(color: _DT.red.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: _DT.red),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: _DT.red, height: 1.35))),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72), fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      color: color.withValues(alpha: 0.14),
      border: Border.all(color: color.withValues(alpha: 0.28)),
    ),
    child: Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w800)),
  );
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, required this.icon, this.busy = false, this.onTap});

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
    onPressed: onTap,
    icon: busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Icon(icon),
    label: Text(label),
    style: ElevatedButton.styleFrom(
      backgroundColor: _DT.purple,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    ),
  );
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _SecondaryButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: _DT.blue,
      side: BorderSide(color: _DT.blue.withValues(alpha: 0.4)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
    ),
  );
}

class _DangerButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _DangerButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: _DT.red,
      side: BorderSide(color: _DT.red.withValues(alpha: 0.4)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
    ),
  );
}

class _IconGlassButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const _IconGlassButton({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
        ),
        child: Icon(icon, color: _DT.purple),
      ),
    ),
  );
}

Future<bool?> _showConfirmDialog(
    BuildContext context, {
      required String title,
      required String message,
      required String confirmText,
      bool danger = false,
    }) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: ElevatedButton.styleFrom(backgroundColor: danger ? _DT.red : _DT.purple, foregroundColor: Colors.white),
          child: Text(confirmText),
        ),
      ],
    ),
  );
}

Color _signalColor(int rssi) {
  if (rssi >= -55) return _DT.green;
  if (rssi >= -70) return _DT.amber;
  return _DT.red;
}

IconData _signalIcon(int rssi) {
  if (rssi >= -55) return Icons.signal_wifi_4_bar_rounded;
  if (rssi >= -70) return Icons.network_wifi_3_bar_rounded;
  if (rssi >= -82) return Icons.network_wifi_2_bar_rounded;
  return Icons.network_wifi_1_bar_rounded;
}

void _showSnack(BuildContext context, String msg, Color color) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: color.withValues(alpha: 0.92),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    margin: const EdgeInsets.all(16),
    duration: const Duration(seconds: 3),
  ));
}

class _DT {
  static const purple = Color(0xFF6C63FF);
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = Color(0xFF64B5F6);
  static const red = Color(0xFFFF5252);
}

class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final IconData actionIcon;
  final VoidCallback? onAction;
  const _GlassAppBar({required this.title, required this.actionIcon, this.onAction});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AppBar(
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          backgroundColor: isDark ? Colors.black.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.3),
          elevation: 0,
          actions: [IconButton(onPressed: onAction, icon: Icon(actionIcon))],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _GCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? glowColor;

  const _GCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.glowColor,
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
                  ? [Colors.white.withValues(alpha: 0.08), Colors.white.withValues(alpha: 0.03)]
                  : [Colors.white.withValues(alpha: 0.65), Colors.white.withValues(alpha: 0.32)],
            ),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.42),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withValues(alpha: 0.30) : Colors.black.withValues(alpha: 0.05),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
              if (glowColor != null) BoxShadow(color: glowColor!.withValues(alpha: 0.13), blurRadius: 28),
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
              colors: isDark ? const [Color(0xFF0B0D1A), Color(0xFF0F1228), Color(0xFF12091F)] : const [Color(0xFFF0F2FF), Color(0xFFEEEBFF), Color(0xFFF0F4FF)],
            ),
          ),
        ),
        Positioned(top: -120, left: -90, child: _Blob(color: isDark ? const Color(0xFF1A1060) : const Color(0xFFCCC8FF), size: w * 0.9)),
        Positioned(top: 300, right: -120, child: _Blob(color: isDark ? const Color(0xFF2A0D50) : const Color(0xFFE8D8FF), size: w * 0.75)),
        Positioned(bottom: 60, left: -60, child: _Blob(color: isDark ? const Color(0xFF0A2A1A) : const Color(0xFFBEF0D8), size: w * 0.65)),
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
      gradient: RadialGradient(colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0)]),
    ),
  );
}
