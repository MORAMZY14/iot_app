import 'dart:convert';
import 'dart:ui' as ui;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'ble_service.dart';
import 'app_logger.dart';

final wifiConfigProvider =
    StateNotifierProvider<EspWifiConfigNotifier, EspWifiConfigState>((ref) {
  return EspWifiConfigNotifier(ref);
});

class EspWifiStatus {
  final String ssid;
  final String ip;
  final int rssi;
  final bool online;
  final int lastSeen;

  const EspWifiStatus({
    required this.ssid,
    required this.ip,
    required this.rssi,
    required this.online,
    required this.lastSeen,
  });

  factory EspWifiStatus.empty() => const EspWifiStatus(
        ssid: '',
        ip: '',
        rssi: 0,
        online: false,
        lastSeen: 0,
      );

  factory EspWifiStatus.fromJson(Map<String, dynamic> json) {
    return EspWifiStatus(
      ssid: (json['ssid'] ?? json['wifiSSID'] ?? '').toString(),
      ip: (json['ip'] ?? '').toString(),
      rssi: _asInt(json['rssi']),
      online: json['online'] == true,
      lastSeen: _asInt(json['lastSeen']),
    );
  }
}

class EspWifiNetwork {
  final String ssid;
  final int rssi;
  final String encryption;
  final int channel;
  final bool secure;
  final bool current;

  const EspWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.encryption,
    required this.channel,
    required this.secure,
    required this.current,
  });

  factory EspWifiNetwork.fromJson(Map<String, dynamic> json) {
    return EspWifiNetwork(
      ssid: (json['ssid'] ?? '').toString(),
      rssi: _asInt(json['rssi']),
      encryption: (json['encryption'] ?? '').toString(),
      channel: _asInt(json['channel']),
      secure: json['secure'] == true,
      current: json['current'] == true,
    );
  }
}

class EspWifiConfigState {
  final EspWifiStatus status;
  final List<EspWifiNetwork> networks;
  final String? espIp;
  final bool isLoadingStatus;
  final bool isScanning;
  final bool isConnecting;
  final String? error;

  const EspWifiConfigState({
    required this.status,
    this.networks = const [],
    this.espIp,
    this.isLoadingStatus = false,
    this.isScanning = false,
    this.isConnecting = false,
    this.error,
  });

  factory EspWifiConfigState.initial() => EspWifiConfigState(
        status: EspWifiStatus.empty(),
      );

  EspWifiConfigState copyWith({
    EspWifiStatus? status,
    List<EspWifiNetwork>? networks,
    String? espIp,
    bool? clearEspIp,
    bool? isLoadingStatus,
    bool? isScanning,
    bool? isConnecting,
    String? error,
    bool clearError = false,
  }) {
    return EspWifiConfigState(
      status: status ?? this.status,
      networks: networks ?? this.networks,
      espIp: clearEspIp == true ? null : espIp ?? this.espIp,
      isLoadingStatus: isLoadingStatus ?? this.isLoadingStatus,
      isScanning: isScanning ?? this.isScanning,
      isConnecting: isConnecting ?? this.isConnecting,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class EspWifiConfigNotifier extends StateNotifier<EspWifiConfigState> {
  final Ref ref;
  EspWifiConfigNotifier(this.ref) : super(EspWifiConfigState.initial());

  static const Duration _commandPollDelay = Duration(seconds: 1);
  static const Duration _scanCommandTimeout = Duration(seconds: 45);
  static const Duration _connectCommandTimeout = Duration(seconds: 18);

  Future<String> _requireUid() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw Exception('User is not signed in');
    }
    return uid;
  }

  Uri _userPath(String uid, String child) {
    return Uri.parse('${AppConfig.databaseUrl}/smartHome/$uid/$child.json');
  }

  Future<Map<String, dynamic>?> _getFirebaseMap(String uid, String child) async {
    final response = await http
        .get(
          _userPath(uid, child),
          headers: {'Cache-Control': 'no-cache'},
        )
        .timeout(AppConfig.mediumTimeout);

    if (response.statusCode != 200) {
      throw Exception('Firebase HTTP ${response.statusCode}: ${response.body}');
    }

    final body = response.body.trim();
    if (body.isEmpty || body == 'null') return null;

    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return null;
  }

  Future<void> _putFirebaseMap(
    String uid,
    String child,
    Map<String, dynamic> value,
  ) async {
    final response = await http
        .put(
          _userPath(uid, child),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(value),
        )
        .timeout(AppConfig.longTimeout);

    if (response.statusCode != 200) {
      throw Exception('Firebase HTTP ${response.statusCode}: ${response.body}');
    }
  }

  Future<void> loadStatus({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoadingStatus: true, clearError: true);
    }

    try {
      final uid = await _requireUid();
      final decoded = await _getFirebaseMap(uid, 'status');

      if (decoded == null) {
        state = state.copyWith(
          isLoadingStatus: false,
          clearEspIp: true,
          error: 'No ESP32 status found yet. Make sure the ESP is registered and online.',
        );
        return;
      }

      final status = EspWifiStatus.fromJson(decoded);
      state = state.copyWith(
        status: status,
        espIp: status.ip.isNotEmpty ? status.ip : null,
        isLoadingStatus: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingStatus: false,
        error: 'Could not read ESP32 Wi-Fi status: $e',
      );
    }
  }

  String _newRequestId(String prefix) {
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}';
  }

  EspWifiStatus _statusFromConnectedMap(Map<String, dynamic>? connected) {
    if (connected == null) return state.status;
    return EspWifiStatus(
      ssid: (connected['ssid'] ?? state.status.ssid).toString(),
      ip: (connected['ip'] ?? state.status.ip).toString(),
      rssi: _asInt(connected['rssi']),
      online: true,
      lastSeen: state.status.lastSeen,
    );
  }

  List<EspWifiNetwork> _parseNetworks(dynamic rawNetworks) {
    final parsed = <EspWifiNetwork>[];
    if (rawNetworks is List) {
      for (final item in rawNetworks) {
        if (item is Map) {
          final network = EspWifiNetwork.fromJson(item.cast<String, dynamic>());
          if (network.ssid.trim().isNotEmpty &&
              !parsed.any((n) => n.ssid == network.ssid)) {
            parsed.add(network);
          }
        }
      }
    }
    parsed.sort((a, b) => b.rssi.compareTo(a.rssi));
    return parsed;
  }

  Future<bool> _scanViaBleIfConnected(BuildContext context) async {
    final ble = ref.read(bleServiceProvider);
    if (!ble.isConnected) return false;
    try {
      final rawNetworks = await ble.scanWifi();
      final parsed = _parseNetworks(rawNetworks);
      state = state.copyWith(
        networks: parsed,
        isScanning: false,
        clearError: true,
      );
      if (context.mounted) {
        _showSnack(context, 'BLE Wi-Fi scan complete', _DT.green);
      }
      return true;
    } catch (e) {
      logDebug('BLE Wi-Fi scan failed: $e');
      return false;
    }
  }

  Future<void> scanFromEsp(BuildContext context) async {
    if (state.isScanning) return;
    state = state.copyWith(isScanning: true, clearError: true);

    try {
      if (await _scanViaBleIfConnected(context)) return;

      final uid = await _requireUid();
      final requestId = _newRequestId('wifi_scan');

      await _putFirebaseMap(uid, 'wifiCommand', {
        'action': 'scan_wifi',
        'requestId': requestId,
        'status': 'pending',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      final deadline = DateTime.now().add(_scanCommandTimeout);
      Map<String, dynamic>? latest;

      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_commandPollDelay);
        latest = await _getFirebaseMap(uid, 'wifiScan');
        if (latest == null || latest['requestId'] != requestId) continue;

        final statusText = (latest['status'] ?? '').toString();
        if (statusText == 'done') {
          final connected = latest['connected'] is Map
              ? (latest['connected'] as Map).cast<String, dynamic>()
              : null;
          final parsed = _parseNetworks(latest['networks']);

          state = state.copyWith(
            status: _statusFromConnectedMap(connected),
            networks: parsed,
            espIp: (connected?['ip'] ?? state.espIp)?.toString(),
            isScanning: false,
            clearError: true,
          );

          if (context.mounted) {
            _showSnack(context, 'ESP32 scan complete from Firebase', _DT.green);
          }
          return;
        }

        if (statusText == 'error') {
          throw Exception(latest['message'] ?? latest['error'] ?? 'ESP32 scan failed');
        }
      }

      throw Exception(
        'ESP32 did not answer the Firebase scan command. Make sure it is powered, connected to Wi-Fi, registered to this account, and running the latest firmware.',
      );
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: _friendlyScanError(e),
      );
      if (context.mounted) {
        _showSnack(context, 'ESP32 scan failed', _DT.red);
      }
    }
  }

  Future<void> connectToNetwork({
    required BuildContext context,
    required String ssid,
    required String password,
  }) async {
    final cleanSsid = ssid.trim();
    if (cleanSsid.isEmpty) {
      _showSnack(context, 'Choose or type a Wi-Fi name first', _DT.red);
      return;
    }
    if (state.isConnecting) return;

    state = state.copyWith(isConnecting: true, clearError: true);

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        await ble.connectWifi(cleanSsid, password);
        state = state.copyWith(isConnecting: false, clearError: true);
        if (context.mounted) {
          _showSnack(context, 'Wi-Fi credentials sent directly by BLE. ESP32 will restart.', _DT.green);
        }
        return;
      }

      final uid = await _requireUid();
      final requestId = _newRequestId('wifi_connect');

      await _putFirebaseMap(uid, 'wifiCommand', {
        'action': 'connect_wifi',
        'requestId': requestId,
        'status': 'pending',
        'ssid': cleanSsid,
        'pass': password,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      final deadline = DateTime.now().add(_connectCommandTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_commandPollDelay);
        final result = await _getFirebaseMap(uid, 'wifiCommandResult');
        if (result == null || result['requestId'] != requestId) continue;

        final statusText = (result['status'] ?? '').toString();
        if (statusText == 'accepted' || statusText == 'restarting' || statusText == 'done') {
          state = state.copyWith(isConnecting: false, clearError: true);
          if (context.mounted) {
            _showSnack(context, 'ESP32 accepted Wi-Fi change. It will reconnect to $cleanSsid', _DT.green);
          }
          return;
        }

        if (statusText == 'error') {
          throw Exception(result['message'] ?? result['error'] ?? 'ESP32 rejected Wi-Fi command');
        }
      }

      state = state.copyWith(
        isConnecting: false,
        error: 'Wi-Fi command was sent, but the ESP32 did not confirm it. If it reconnects, status will update after the next heartbeat.',
      );
      if (context.mounted) {
        _showSnack(context, 'Command sent, waiting for ESP32 reconnect', _DT.amber);
      }
    } catch (e) {
      state = state.copyWith(
        isConnecting: false,
        error: 'Could not send Wi-Fi credentials through Firebase: $e',
      );
      if (context.mounted) {
        _showSnack(context, 'Wi-Fi change failed', _DT.red);
      }
    }
  }

  Future<void> forgetNetwork(BuildContext context) async {
    if (state.isConnecting) return;
    state = state.copyWith(isConnecting: true, clearError: true);

    try {
      final ble = ref.read(bleServiceProvider);
      if (ble.isConnected) {
        await ble.forgetWifi();
        state = state.copyWith(isConnecting: false, clearError: true);
        if (context.mounted) {
          _showSnack(context, 'Forget command sent directly by BLE. ESP32 will restart.', _DT.amber);
        }
        return;
      }

      final uid = await _requireUid();
      final requestId = _newRequestId('wifi_forget');

      await _putFirebaseMap(uid, 'wifiCommand', {
        'action': 'forget_wifi',
        'requestId': requestId,
        'status': 'pending',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      final deadline = DateTime.now().add(_connectCommandTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_commandPollDelay);
        final result = await _getFirebaseMap(uid, 'wifiCommandResult');
        if (result == null || result['requestId'] != requestId) continue;

        final statusText = (result['status'] ?? '').toString();
        if (statusText == 'accepted' || statusText == 'restarting' || statusText == 'done') {
          state = state.copyWith(isConnecting: false, clearError: true);
          if (context.mounted) {
            _showSnack(context, 'ESP32 will restart into setup mode', _DT.amber);
          }
          return;
        }

        if (statusText == 'error') {
          throw Exception(result['message'] ?? result['error'] ?? 'ESP32 rejected forget command');
        }
      }

      state = state.copyWith(
        isConnecting: false,
        error: 'Forget command was sent, but the ESP32 did not confirm it.',
      );
    } catch (e) {
      state = state.copyWith(
        isConnecting: false,
        error: 'Forget network failed: $e',
      );
      if (context.mounted) {
        _showSnack(context, 'Forget failed', _DT.red);
      }
    }
  }
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _friendlyScanError(Object e) {
  final raw = e.toString();
  final lower = raw.toLowerCase();

  if (lower.contains('timeout') || lower.contains('did not answer')) {
    return 'ESP32 did not answer the Firebase Wi-Fi command. Make sure the ESP32 is powered on, connected to the internet, claimed by this account, and running the latest firmware from this chat.';
  }

  if (lower.contains('permission') || lower.contains('401') || lower.contains('403')) {
    return 'Firebase rejected the Wi-Fi command. Check your Realtime Database rules for smartHome/<uid>/wifiCommand and wifiScan.';
  }

  return 'ESP32 Wi-Fi command failed: $raw';
}

class _DT {
  static const purple = Color(0xFF6C63FF);
  static const green = Color(0xFF4DFFA0);
  static const amber = Color(0xFFFFB347);
  static const blue = Color(0xFF64B5F6);
  static const red = Color(0xFFFF5252);
}

void _showSnack(BuildContext context, String msg, Color color) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: color.withValues(alpha: 0.92),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    margin: const EdgeInsets.all(16),
    duration: const Duration(seconds: 2),
  ));
}

class WifiConfigPage extends ConsumerStatefulWidget {
  const WifiConfigPage({super.key});

  @override
  ConsumerState<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends ConsumerState<WifiConfigPage> {
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final notifier = ref.read(wifiConfigProvider.notifier);
      await notifier.loadStatus();
      // Do not auto-scan on page open. The user can tap Scan ESP Networks.
      // This avoids immediate CORS/network errors while the ESP is still reconnecting.
    });
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _selectNetwork(EspWifiNetwork network) {
    HapticFeedback.selectionClick();
    _ssidController.text = network.ssid;
  }

  Future<void> _connect() async {
    await ref.read(wifiConfigProvider.notifier).connectToNetwork(
          context: context,
          ssid: _ssidController.text,
          password: _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wifiConfigProvider);
    final notifier = ref.read(wifiConfigProvider.notifier);
    final bleStatus = ref.watch(bleServiceProvider).currentStatus;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _GlassAppBar(
        title: 'ESP32 Wi-Fi Manager',
        onRefresh: state.isScanning ? null : () => notifier.scanFromEsp(context),
      ),
      body: _WallpaperBackground(
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async {
              await notifier.loadStatus(silent: true);
              if (context.mounted) await notifier.scanFromEsp(context);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
              children: [
                _CurrentWifiCard(
                  status: state.status,
                  espIp: state.espIp,
                  isLoading: state.isLoadingStatus,
                  onRefresh: () => notifier.loadStatus(),
                ),
                const SizedBox(height: 14),
                _ConnectCard(
                  ssidController: _ssidController,
                  passwordController: _passwordController,
                  obscurePassword: _obscurePassword,
                  isConnecting: state.isConnecting,
                  onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
                  onConnect: _connect,
                  onForget: () => notifier.forgetNetwork(context),
                ),
                const SizedBox(height: 14),
                _NearbyNetworksCard(
                  networks: state.networks,
                  isScanning: state.isScanning,
                  error: state.error,
                  currentSsid: state.status.ssid,
                  onScan: () => notifier.scanFromEsp(context),
                  onSelect: _selectNetwork,
                ),
                const SizedBox(height: 12),
                _HintCard(
                  text:
                      'This scan runs remotely through Firebase. Your phone does not need to be on the same Wi-Fi as the ESP32; the ESP32 scans using its own antenna and uploads the results.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onRefresh;

  const _GlassAppBar({required this.title, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AppBar(
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          backgroundColor: isDark
              ? Colors.black.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.34),
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            IconButton(
              tooltip: 'Ask ESP32 to scan via Firebase',
              onPressed: onRefresh,
              icon: const Icon(Icons.radar_rounded),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
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
            size: w * 0.9,
          ),
        ),
        Positioned(
          top: 280,
          right: -110,
          child: _Blob(
            color: isDark ? const Color(0xFF12294D) : const Color(0xFFD8EAFF),
            size: w * 0.78,
          ),
        ),
        Positioned(
          bottom: 80,
          left: -30,
          child: _Blob(
            color: isDark ? const Color(0xFF0A2A1A) : const Color(0xFFBEF0D8),
            size: w * 0.62,
          ),
        ),
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
            colors: [color.withValues(alpha: 0.48), color.withValues(alpha: 0)],
          ),
        ),
      );
}

class _GCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? glowColor;

  const _GCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [Colors.white.withValues(alpha: 0.08), Colors.white.withValues(alpha: 0.035)]
                  : [Colors.white.withValues(alpha: 0.68), Colors.white.withValues(alpha: 0.36)],
            ),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.46),
              width: 0.9,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withValues(alpha: 0.32) : Colors.black.withValues(alpha: 0.06),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
              if (glowColor != null)
                BoxShadow(color: glowColor!.withValues(alpha: 0.18), blurRadius: 28),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _CurrentWifiCard extends StatelessWidget {
  final EspWifiStatus status;
  final String? espIp;
  final bool isLoading;
  final VoidCallback onRefresh;

  const _CurrentWifiCard({
    required this.status,
    required this.espIp,
    required this.isLoading,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final connected = status.online && (status.ssid.isNotEmpty || (espIp ?? '').isNotEmpty);
    final ssid = status.ssid.isNotEmpty ? status.ssid : 'Unknown network';

    return _GCard(
      glowColor: connected ? _DT.green : _DT.amber,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    colors: connected
                        ? [_DT.green.withValues(alpha: 0.9), _DT.blue.withValues(alpha: 0.75)]
                        : [_DT.amber.withValues(alpha: 0.9), _DT.purple.withValues(alpha: 0.7)],
                  ),
                ),
                child: Icon(
                  connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? 'Connected to' : 'ESP32 Wi-Fi status',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.56),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connected ? ssid : 'Not available',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh status',
                onPressed: isLoading ? null : onRefresh,
                icon: isLoading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(icon: Icons.router_rounded, label: 'IP', value: espIp ?? status.ip.ifEmpty('Unknown')),
              _InfoChip(icon: Icons.network_wifi_rounded, label: 'RSSI', value: status.rssi == 0 ? 'Unknown' : '${status.rssi} dBm'),
              _InfoChip(icon: Icons.circle, label: 'State', value: connected ? 'Online' : 'Offline'),
            ],
          ),
        ],
      ),
    );
  }
}

extension _StringEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.055),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _DT.purple),
          const SizedBox(width: 6),
          Text('$label: ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          Text(value, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72))),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  final TextEditingController ssidController;
  final TextEditingController passwordController;
  final bool obscurePassword;
  final bool isConnecting;
  final VoidCallback onToggleObscure;
  final VoidCallback onConnect;
  final VoidCallback onForget;

  const _ConnectCard({
    required this.ssidController,
    required this.passwordController,
    required this.obscurePassword,
    required this.isConnecting,
    required this.onToggleObscure,
    required this.onConnect,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(icon: Icons.edit_rounded, title: 'Change ESP32 network remotely'),
          const SizedBox(height: 14),
          TextField(
            controller: ssidController,
            enabled: !isConnecting,
            textInputAction: TextInputAction.next,
            decoration: _inputDecoration(context, 'Wi-Fi name / SSID', Icons.wifi_rounded),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            enabled: !isConnecting,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onConnect(),
            decoration: _inputDecoration(context, 'Password', Icons.lock_rounded).copyWith(
              suffixIcon: IconButton(
                onPressed: onToggleObscure,
                icon: Icon(obscurePassword ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isConnecting ? null : onConnect,
                  icon: isConnecting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.power_settings_new_rounded),
                  label: Text(isConnecting ? 'Sending...' : 'Send to ESP32'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _DT.purple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isConnecting ? null : onForget,
              icon: const Icon(Icons.delete_forever_rounded, color: _DT.red),
              label: const Text('Forget saved Wi-Fi remotely and restart setup mode'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _DT.red,
                side: BorderSide(color: _DT.red.withValues(alpha: 0.45)),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(BuildContext context, String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _DT.purple, width: 1.6),
      ),
    );
  }
}

class _NearbyNetworksCard extends StatelessWidget {
  final List<EspWifiNetwork> networks;
  final bool isScanning;
  final String? error;
  final String currentSsid;
  final VoidCallback onScan;
  final ValueChanged<EspWifiNetwork> onSelect;

  const _NearbyNetworksCard({
    required this.networks,
    required this.isScanning,
    required this.error,
    required this.currentSsid,
    required this.onScan,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return _GCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: _SectionTitle(icon: Icons.radar_rounded, title: 'Nearby networks')),
              _MiniButton(
                label: isScanning ? 'Scanning' : 'Remote Scan',
                icon: Icons.refresh_rounded,
                onTap: isScanning ? null : onScan,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator(color: _DT.purple)),
            )
          else if (error != null)
            _InlineError(message: error!, onRetry: onScan)
          else if (networks.isEmpty)
            _EmptyNetworks(onScan: onScan)
          else
            ...networks.map((network) {
              final isCurrent = network.current || network.ssid == currentSsid;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NetworkTile(
                  network: network,
                  isCurrent: isCurrent,
                  onTap: () => onSelect(network),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _NetworkTile extends StatelessWidget {
  final EspWifiNetwork network;
  final bool isCurrent;
  final VoidCallback onTap;

  const _NetworkTile({required this.network, required this.isCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: isCurrent ? 0.085 : 0.045),
            border: Border.all(
              color: isCurrent ? _DT.green.withValues(alpha: 0.55) : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  color: _signalColor(network.rssi).withValues(alpha: 0.14),
                ),
                child: Icon(_signalIcon(network.rssi), color: _signalColor(network.rssi)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      network.ssid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(network.secure ? Icons.lock_rounded : Icons.lock_open_rounded, size: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
                        const SizedBox(width: 4),
                        Text(
                          '${network.rssi} dBm${network.channel > 0 ? ' • Ch ${network.channel}' : ''}',
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.56)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: _DT.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Current', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _DT.green)),
                )
              else
                Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.34)),
            ],
          ),
        ),
      ),
    );
  }

  Color _signalColor(int rssi) {
    if (rssi >= -58) return _DT.green;
    if (rssi >= -72) return _DT.amber;
    return _DT.red;
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -58) return Icons.signal_wifi_4_bar_rounded;
    if (rssi >= -72) return Icons.wifi_rounded;
    return Icons.wifi_off_rounded;
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _DT.purple, size: 20),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
      ],
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _MiniButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: _DT.purple.withValues(alpha: 0.13),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: _DT.purple),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _DT.purple)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _DT.red.withValues(alpha: 0.09),
        border: Border.all(color: _DT.red.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          const Icon(Icons.error_outline_rounded, color: _DT.red, size: 30),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _DT.red, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          _MiniButton(label: 'Retry scan', icon: Icons.refresh_rounded, onTap: onRetry),
        ],
      ),
    );
  }
}

class _EmptyNetworks extends StatelessWidget {
  final VoidCallback onScan;

  const _EmptyNetworks({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.045),
      ),
      child: Column(
        children: [
          Icon(Icons.wifi_find_rounded, size: 42, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45)),
          const SizedBox(height: 8),
          const Text('No networks loaded yet', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Tap remote scan to ask the ESP32 through Firebase to search nearby Wi-Fi networks.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)),
          ),
          const SizedBox(height: 12),
          _MiniButton(label: 'Remote scan', icon: Icons.radar_rounded, onTap: onScan),
        ],
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  final String text;

  const _HintCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: _DT.blue.withValues(alpha: 0.10),
        border: Border.all(color: _DT.blue.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: _DT.blue, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
