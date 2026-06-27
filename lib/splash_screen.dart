import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';
import 'dashboard_page.dart';
import 'login_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  // 🔥 The exact purple hex code from your logo background
  final Color logoBackground = const Color(0xFF4A2E98);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🔥 MATCH THE BACKGROUND COLOR TO YOUR LOGO
      backgroundColor: logoBackground,
      body: Center(
        child: ref.watch(authServiceProvider).when(
          data: (authService) {
            // Wait a tiny bit for the animation to be visible
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) _navigate(authService);
            });
            return _buildAnimatedLogo();
          },
          loading: () => _buildAnimatedLogo(),
          error: (error, stack) => Center(
            child: Text(
              'Error: $error',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  void _navigate(AuthService authService) {
    final user = authService.currentUser;
    if (user != null && user.emailVerified) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const DashboardPage()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  Widget _buildAnimatedLogo() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 🔥 ANIMATED LOGO
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: child,
            );
          },
          child: Container(
            width: 200, // Slightly larger because it's a square logo
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1), // Subtle glow
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              // ✅ SHOW YOUR LOGO HERE
              child: Image.asset(
                'assets/images/logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        const SizedBox(height: 40),

        // 🔥 ANIMATED APP NAME (White text to match the logo's white arrow)
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOut,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: child,
            );
          },
          child: const Text(
            'Smart Home',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Colors.white, // White to match your logo's white arrow
              letterSpacing: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 30),

        // 🔥 PULSING LOADER (Pink to match your logo accent)
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.5, end: 1.0),
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeInOut,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: child,
            );
          },
          child: const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              color: Color(0xFFE91E63), // Bright pink to match your logo
              strokeWidth: 3,
            ),
          ),
        ),
      ],
    );
  }
}