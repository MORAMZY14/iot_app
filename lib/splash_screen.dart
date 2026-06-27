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
      backgroundColor: logoBackground,
      body: Center(
        child: ref.watch(authServiceProvider).when(
          data: (authService) {
            // 🔥 Wait a full 3 seconds so the user sees "Loading..."
            Future.delayed(const Duration(seconds: 3), () {
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
        // 🔥 ANIMATED LOGO (No circle background)
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
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Image.asset(
              'assets/images/logo.png',
              width: 200,
              height: 200,
              fit: BoxFit.contain,
            ),
          ),
        ),
        const SizedBox(height: 40),

        // 🔥 ANIMATED APP NAME
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
              color: Colors.white,
              letterSpacing: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 30),

        // 🔥 PULSING LOADER
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
              color: Color(0xFFE91E63),
              strokeWidth: 3,
            ),
          ),
        ),
        const SizedBox(height: 20),

        // 🔥 "Loading..." text
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeIn,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: child,
            );
          },
          child: const Text(
            'Loading...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white70,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ],
    );
  }
}