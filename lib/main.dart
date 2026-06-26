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

// 🔥 FIREBASE CONFIGURATION FOR WEB
// COPY YOUR EXACT FIREBASE CONFIG FROM index.html HERE
const firebaseConfig = {
  'apiKey': 'AIzaSyAsgr28RWuPj4MzbO23LpayEYg1wYSJkqs',
  'authDomain': 'iot-smart-home-81abd.firebaseapp.com',
  'databaseURL': 'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app',
  'projectId': 'iot-smart-home-81abd',
  'storageBucket': 'iot-smart-home-81abd.firebasestorage.app',
  'messagingSenderId': '899142789545',
  'appId': '1:899142789545:web:1a64f8250e9f4f6de2fcb8',
};

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔥 FIX: Initialize Firebase with proper options for Web
  try {
    if (kIsWeb) {
      // Web: Use explicit FirebaseOptions
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: firebaseConfig['apiKey']!,
          authDomain: firebaseConfig['authDomain']!,
          databaseURL: firebaseConfig['databaseURL']!,
          projectId: firebaseConfig['projectId']!,
          storageBucket: firebaseConfig['storageBucket']!,
          messagingSenderId: firebaseConfig['messagingSenderId']!,
          appId: firebaseConfig['appId']!,
        ),
      );
    } else {
      // Mobile: Use default initialization (reads google-services.json / GoogleService-Info.plist)
      await Firebase.initializeApp();
    }
    debugPrint('🔥 Firebase initialized successfully');
  } catch (e) {
    debugPrint('🔥🔥🔥 Firebase initialization error: $e');
  }

  // Request permissions (Mobile only)
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

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
      home: FutureBuilder(
        // 🔥 FIX: We simply wait for the already initialized app
        future: Firebase.apps.isNotEmpty ? Future.value(Firebase.app()) : Future.error('Firebase not initialized'),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
              ),
            );
          }

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

          return StreamBuilder<User?>(
            stream: authService.userChanges,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.active) {
                final user = snapshot.data;
                if (user != null && user.emailVerified) {
                  return const DashboardPage();
                } else {
                  return const LoginScreen();
                }
              }
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