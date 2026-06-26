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

const String appVersion = '1.0.39';

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

  // 🔥 Initialize Firebase BEFORE runApp
  try {
    if (kIsWeb) {
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
      // Mobile: reads GoogleService-Info.plist (iOS) / google-services.json (Android)
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
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      // ✅ Firebase is already initialized before runApp(), no FutureBuilder needed
      home: StreamBuilder<User?>(
        stream: authService.userChanges,
        builder: (context, snapshot) {
          // Still waiting for auth state
          if (snapshot.connectionState != ConnectionState.active) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
              ),
            );
          }

          final user = snapshot.data;

          // User is logged in and email is verified
          if (user != null && user.emailVerified) {
            return const DashboardPage();
          }

          // Not logged in or email not verified
          return const LoginScreen();
        },
      ),
      routes: {
        '/provision': (context) => const ProvisionPage(),
        '/wifiConfig': (context) => const WifiConfigPage(),
      },
    );
  }
}
