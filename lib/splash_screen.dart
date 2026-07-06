import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'dashboard_page.dart';
import 'login_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _navigationStarted = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _scale = Tween<double>(begin: 0.92, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _navigate(AuthService authService) async {
    if (_navigationStarted) return;
    _navigationStarted = true;

    // Keep the branding visible briefly, but do not force the user to wait 3 seconds.
    await Future.delayed(const Duration(milliseconds: 1150));
    if (!mounted) return;

    final user = authService.currentUser;
    final destination = user != null && user.emailVerified
        ? const DashboardPage()
        : const LoginScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AuthService>>(authServiceProvider, (previous, next) {
      next.whenData((authService) => unawaited(_navigate(authService)));
    });

    final authState = ref.watch(authServiceProvider);
    authState.whenData((authService) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_navigate(authService));
      });
    });

    return Scaffold(
      body: _SplashBackground(
        child: SafeArea(
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _scale,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const _SplashLogo(),
                    const SizedBox(height: 30),
                    Text(
                      'Smart Home',
                      style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Fast local control • Firebase sync • BLE backup',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 36),
                    authState.when(
                      data: (_) => const _LoadingPill(text: 'Preparing dashboard'),
                      loading: () => const _LoadingPill(text: 'Starting services'),
                      error: (error, _) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          'Startup error: $error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashBackground extends StatelessWidget {
  final Widget child;
  const _SplashBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF130D33), Color(0xFF21105B), Color(0xFF071826)],
              ),
            ),
          ),
          const Positioned(top: -130, left: -100, child: _SplashGlow(size: 360, color: Color(0xFF6C63FF))),
          const Positioned(top: 170, right: -160, child: _SplashGlow(size: 360, color: Color(0xFF4DDCFF))),
          const Positioned(bottom: -140, left: 40, child: _SplashGlow(size: 320, color: Color(0xFF4DFFA0))),
          child,
        ],
      ),
    );
  }
}

class _SplashGlow extends StatelessWidget {
  final double size;
  final Color color;
  const _SplashGlow({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withOpacity(0.38), color.withOpacity(0)],
          ),
        ),
      ),
    );
  }
}

class _SplashLogo extends StatelessWidget {
  const _SplashLogo();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 132,
          height: 132,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white.withOpacity(0.24), Colors.white.withOpacity(0.08)],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.22)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6C63FF).withOpacity(0.34),
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Center(
            child: Image.asset(
              'assets/images/logo.png',
              width: 92,
              height: 92,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.home_rounded,
                size: 72,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingPill extends StatelessWidget {
  final String text;
  const _LoadingPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
