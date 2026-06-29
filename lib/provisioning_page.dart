import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'app_constants.dart';

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

  const ProvisionState({
    this.status = ProvisionStatus.initial,
    this.networks = const [],
    this.errorMessage,
  });

  ProvisionState copyWith({
    ProvisionStatus? status,
    List<WifiNetwork>? networks,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return ProvisionState(
      status: status ?? this.status,
      networks: networks ?? this.networks,
      errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
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
  ProvisionNotifier() : super(const ProvisionState());

  Future<void> scanNetworks() async {
    if (state.status == ProvisionStatus.loading) return;
    state = state.copyWith(status: ProvisionStatus.loading, clearErrorMessage: true);

    try {
      final response = await http
          .get(Uri.parse('${AppConfig.esp32ApBaseUrl}/scan'))
          .timeout(AppConfig.longTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> networksJson = data['networks'] ?? [];
        final networks = networksJson
            .map((json) => WifiNetwork.fromJson(json))
            .toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
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
    state = state.copyWith(status: ProvisionStatus.loading, clearErrorMessage: true);

    try {
      final response = await http
          .post(
        Uri.parse('${AppConfig.esp32ApBaseUrl}/save'),
        body: {'ssid': ssid, 'pass': password},
      )
          .timeout(AppConfig.longTimeout);

      if (response.statusCode == 200) {
        state = state.copyWith(status: ProvisionStatus.success);
        if (context.mounted) {
          _showSnack(context, 'Credentials sent. ESP32 will now reboot.', color: _DT.green);
          Navigator.pop(context);
        }
      } else {
        state = state.copyWith(
          status: ProvisionStatus.error,
          errorMessage: 'Save failed (HTTP ${response.statusCode})',
        );
        if (context.mounted) {
          _showSnack(context, state.errorMessage!, color: _DT.red);
        }
      }
    } catch (e) {
      state = state.copyWith(
        status: ProvisionStatus.error,
        errorMessage: 'Error: $e',
      );
      if (context.mounted) {
        _showSnack(context, state.errorMessage!, color: _DT.red);
      }
    }
  }

  void reset() {
    state = const ProvisionState();
  }
}

// ============================================================
// 2. Design tokens and widgets (from your dashboard)
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

void _showSnack(BuildContext context, String msg, {Color color = Colors.white}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: color.withValues(alpha: 0.9),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    margin: const EdgeInsets.all(16),
    duration: const Duration(seconds: 2),
  ));
}

// ============================================================
// 3. UI Widget (Redesigned)
// ============================================================
class ProvisionPage extends ConsumerStatefulWidget {
  const ProvisionPage({super.key});

  @override
  ConsumerState<ProvisionPage> createState() => _ProvisionPageState();
}

class _ProvisionPageState extends ConsumerState<ProvisionPage> {
  final TextEditingController _passwordController = TextEditingController();
  late final ProvisionNotifier _provisionNotifier;

  @override
  void initState() {
    super.initState();
    _provisionNotifier = ref.read(provisionProvider.notifier);
    Future.microtask(() {
      if (!mounted) return;
      _provisionNotifier.scanNetworks();
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    // Do not call ref.read() here. Riverpod refs cannot be used after
    // the ConsumerState starts disposing/unmounting.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provisionState = ref.watch(provisionProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _GlassAppBar(
        title: 'Provision ESP32',
        actionIcon: Icons.refresh,
        onAction: provisionState.status == ProvisionStatus.loading
            ? null
            : () => ref.read(provisionProvider.notifier).scanNetworks(),
      ),
      body: _WallpaperBackground(
        child: _buildBody(provisionState),
      ),
    );
  }

  Widget _buildBody(ProvisionState state) {
    if (state.status == ProvisionStatus.loading && state.networks.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _DT.purple));
    }

    if (state.status == ProvisionStatus.error && state.networks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _GCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off, size: 64, color: _DT.red.withValues(alpha: 0.7)),
                const SizedBox(height: 16),
                Text(state.errorMessage!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                _PillBtn(label: 'Retry', onTap: () => ref.read(provisionProvider.notifier).scanNetworks()),
              ],
            ),
          ),
        ),
      );
    }

    if (state.networks.isEmpty) {
      return Center(
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: const Text('No Wi‑Fi networks found'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(provisionProvider.notifier).scanNetworks(),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: state.networks.length,
        itemBuilder: (context, index) {
          final net = state.networks[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _GCard(
              padding: const EdgeInsets.all(12),
              child: ListTile(
                leading: Icon(
                  net.isOpen ? Icons.lock_open : Icons.lock,
                  color: net.isOpen ? _DT.green : _DT.amber,
                ),
                title: Text(net.ssid, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${net.rssi} dBm'),
                trailing: state.status == ProvisionStatus.loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _DT.purple))
                    : Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
                onTap: state.status == ProvisionStatus.loading ? null : () => _showPasswordDialog(net.ssid),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPasswordDialog(String ssid) {
    _passwordController.clear();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.transparent,
        child: _GCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Connect to $ssid', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final password = _passwordController.text.trim();
                        if (password.isEmpty) {
                          _showSnack(ctx, 'Please enter password', color: _DT.red);
                          return;
                        }
                        Navigator.pop(ctx);
                        ref.read(provisionProvider.notifier).sendCredentials(ssid, password, context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _DT.purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
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
