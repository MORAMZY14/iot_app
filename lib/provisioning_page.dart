import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'ble_service.dart';

class ProvisionWifiNetwork {
  final String ssid;
  final int rssi;
  final bool secure;
  final String encryption;

  const ProvisionWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secure,
    required this.encryption,
  });

  factory ProvisionWifiNetwork.fromMap(Map<String, dynamic> map) {
    final enc = (map['encryption'] ?? '').toString();
    final secureValue = map['secure'];
    return ProvisionWifiNetwork(
      ssid: (map['ssid'] ?? '').toString(),
      rssi: map['rssi'] is num ? (map['rssi'] as num).toInt() : -100,
      secure: secureValue is bool ? secureValue : enc.toLowerCase() != 'open',
      encryption: enc.isEmpty ? 'secured' : enc,
    );
  }
}

class ProvisionPage extends ConsumerStatefulWidget {
  const ProvisionPage({super.key});

  @override
  ConsumerState<ProvisionPage> createState() => _ProvisionPageState();
}

class _ProvisionPageState extends ConsumerState<ProvisionPage> {
  final TextEditingController _manualSsidController = TextEditingController();
  StreamSubscription<BleStatus>? _bleSub;

  List<ProvisionWifiNetwork> _networks = const [];
  bool _scanning = false;
  bool _busy = false;
  String? _error;
  String _source = 'Setup AP';

  @override
  void initState() {
    super.initState();
    _bleSub = ref.read(bleServiceProvider).statusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _manualSsidController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _apGetJson(String path, {Duration timeout = const Duration(seconds: 12)}) async {
    final response = await http
        .get(Uri.parse('${AppConfig.esp32ApBaseUrl}$path'), headers: const {'Cache-Control': 'no-cache'})
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 setup AP returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Invalid ESP32 setup response');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _apPostSave(String ssid, String password) async {
    final response = await http
        .post(
      Uri.parse('${AppConfig.esp32ApBaseUrl}/save'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'ssid': ssid, 'pass': password},
    )
        .timeout(AppConfig.longTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ESP32 setup AP returned HTTP ${response.statusCode}: ${response.body}');
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
      if (ble.isConnected) {
        raw = await ble.scanWifi();
        _source = 'Bluetooth';
      } else {
        final data = await _apGetJson('/scan');
        final rawList = data['networks'];
        raw = rawList is List ? rawList.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];
        _source = 'ESP32_Config AP';
      }

      final networks = raw
          .map(ProvisionWifiNetwork.fromMap)
          .where((n) => n.ssid.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      if (!mounted) return;
      setState(() {
        _networks = networks;
        _scanning = false;
        if (networks.isEmpty) _error = 'ESP32 scanned successfully, but no networks were found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = 'Could not scan from ESP32. Connect your phone to ESP32_Config Wi-Fi, or connect by Bluetooth backup first.\n\n$e';
      });
    }
  }

  Future<void> _saveNetwork(String ssid, String password) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        final ok = await ble.connectWifi(ssid, password);
        if (!ok) throw Exception('ESP32 rejected Bluetooth Wi-Fi command');
      } else {
        await _apPostSave(ssid, password);
      }
      if (!mounted) return;
      _showSnack(context, 'Wi-Fi saved. ESP32 is restarting.', _DT.green);
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to save Wi-Fi credentials.\n\n$e';
      });
      _showSnack(context, 'Failed to save Wi-Fi', _DT.red);
    }
  }

  Future<void> _openConnectSheet({ProvisionWifiNetwork? network}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _ProvisionConnectSheet(
        initialSsid: network?.ssid ?? _manualSsidController.text,
        secure: network?.secure ?? true,
        onConnect: (ssid, password) async {
          Navigator.pop(sheetContext);
          await _saveNetwork(ssid, password);
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
        title: 'Provision ESP32',
        actionIcon: Icons.refresh_rounded,
        onAction: _scanning ? null : _scanNetworks,
      ),
      body: _WallpaperBackground(
        child: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: [
              const SizedBox(height: kToolbarHeight + 8),
              _GCard(
                padding: const EdgeInsets.all(18),
                glowColor: bleConnected ? _DT.blue : _DT.purple,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: _DT.purple.withValues(alpha: 0.15),
                          ),
                          child: const Icon(Icons.router_rounded, color: _DT.purple),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Set up ESP32 Wi-Fi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                              SizedBox(height: 4),
                              Text('Use Bluetooth backup, or connect your phone to ESP32_Config.', style: TextStyle(color: Colors.grey)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _InfoChip(icon: Icons.wifi_tethering_rounded, text: _source),
                        _InfoChip(icon: Icons.bluetooth_rounded, text: bleConnected ? 'Bluetooth connected' : 'Bluetooth optional'),
                        const _InfoChip(icon: Icons.lock_rounded, text: 'AP password: 12345678'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _PrimaryButton(
                            label: _scanning ? 'Scanning...' : 'Scan networks',
                            icon: Icons.wifi_find_rounded,
                            busy: _scanning,
                            onTap: _scanning ? null : _scanNetworks,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _IconGlassButton(
                          icon: Icons.bluetooth_rounded,
                          tooltip: 'Connect Bluetooth',
                          onTap: bleConnected ? null : () => ref.read(bleServiceProvider).connect(),
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
                _SetupInstructions(onScan: _scanNetworks)
              else
                ..._networks.map((network) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProvisionNetworkTile(
                    network: network,
                    onTap: () => _openConnectSheet(network: network),
                  ),
                )),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProvisionConnectSheet extends StatefulWidget {
  final String initialSsid;
  final bool secure;
  final Future<void> Function(String ssid, String password) onConnect;

  const _ProvisionConnectSheet({required this.initialSsid, required this.secure, required this.onConnect});

  @override
  State<_ProvisionConnectSheet> createState() => _ProvisionConnectSheetState();
}

class _ProvisionConnectSheetState extends State<_ProvisionConnectSheet> {
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
              const Text('Connect ESP32 to network', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              const Text('The ESP32 will save this network and restart.', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 18),
              TextField(
                controller: _ssidController,
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
                label: 'Save and restart ESP32',
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

class _SetupInstructions extends StatelessWidget {
  final VoidCallback onScan;
  const _SetupInstructions({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Icon(Icons.wifi_tethering_rounded, size: 62, color: _DT.purple.withValues(alpha: 0.9)),
          const SizedBox(height: 12),
          const Text('No networks scanned yet', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          const Text(
            'Option 1: Connect Bluetooth backup, then tap Scan.\n\nOption 2: Connect your phone to ESP32_Config Wi-Fi using password 12345678, then tap Scan.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, height: 1.45),
          ),
          const SizedBox(height: 18),
          _PrimaryButton(label: 'Scan now', icon: Icons.radar_rounded, onTap: onScan),
        ],
      ),
    );
  }
}

class _ProvisionNetworkTile extends StatelessWidget {
  final ProvisionWifiNetwork network;
  final VoidCallback onTap;
  const _ProvisionNetworkTile({required this.network, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(12),
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
        subtitle: Text('${network.encryption} • ${network.rssi} dBm'),
        trailing: Icon(network.secure ? Icons.lock_rounded : Icons.lock_open_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
        onTap: onTap,
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65)),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72), fontWeight: FontWeight.w700)),
    ]),
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
    icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(icon),
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
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)),
        child: Icon(icon, color: _DT.purple),
      ),
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

  const _GCard({required this.child, this.padding = const EdgeInsets.all(16), this.borderRadius = const BorderRadius.all(Radius.circular(22)), this.glowColor});

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
              colors: isDark ? [Colors.white.withValues(alpha: 0.08), Colors.white.withValues(alpha: 0.03)] : [Colors.white.withValues(alpha: 0.65), Colors.white.withValues(alpha: 0.32)],
            ),
            border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.42), width: 0.8),
            boxShadow: [
              BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.30) : Colors.black.withValues(alpha: 0.05), blurRadius: 24, offset: const Offset(0, 8)),
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
    decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0)])),
  );
}
