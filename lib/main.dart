import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';
import 'auth_service.dart';
import 'login_screen.dart';

const String appVersion = '1.0.31';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch any build errors to prevent the blank screen
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline_rounded, size: 56, color: Color(0xFF6C63FF)),
                const SizedBox(height: 16),
                const Text(
                  'Something went wrong',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF6C63FF)),
                ),
                const SizedBox(height: 8),
                Text(
                  details.exception.toString(),
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  // Firebase initialization is moved INSIDE MyApp to handle it safely
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final authService = ref.watch(authServiceProvider);

    return MaterialApp(
      key: ValueKey(themeMode),
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      // FUTURE BUILDER to wait for Firebase initialization
      home: FutureBuilder(
        future: Firebase.initializeApp(),
        builder: (context, snapshot) {
          // 1. Show loading spinner while initializing
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
              ),
            );
          }

          // 2. Show error if initialization fails
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 56, color: Colors.red),
                      const SizedBox(height: 16),
                      const Text(
                        'Firebase Initialization Error',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.red),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${snapshot.error}',
                        style: const TextStyle(fontSize: 14, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          // 3. Firebase initialized successfully -> handle Auth
          return StreamBuilder<User?>(
            stream: authService.userChanges,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.active) {
                final user = snapshot.data;
                if (user != null && user.emailVerified) {
                  // User is authenticated and verified
                  return const DashboardPage();
                } else {
                  // User is not authenticated or not verified
                  return const LoginScreen();
                }
              }
              // Loading auth state
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
                ),
              );
            },
          );
        },
      ),
      routes: {
        '/provision': (context) => const ProvisionPage(),
        '/wifiConfig': (context) => const WifiConfigPage(),
      },
    );
  }
}