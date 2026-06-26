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

const String appVersion = '1.0.42';

const firebaseConfig = {
  'apiKey': 'AIzaSyAsgr28RWuPj4MzbO23LpayEYg1wYSJkqs',
  'authDomain': 'iot-smart-home-81abd.firebaseapp.com',
  'databaseURL':
      'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app',
  'projectId': 'iot-smart-home-81abd',
  'storageBucket': 'iot-smart-home-81abd.firebasestorage.app',
  'messagingSenderId': '899142789545',
  'appId': '1:899142789545:web:1a64f8250e9f4f6de2fcb8',
};

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      await Firebase.initializeApp();
    }

    debugPrint("✅ Firebase initialized successfully");

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    }

    runApp(const ProviderScope(child: MyApp()));
  } catch (e, stackTrace) {
    debugPrint("❌ Firebase Initialization Failed");
    debugPrint(e.toString());
    debugPrint(stackTrace.toString());

    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                "Firebase Initialization Failed\n\n$e",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  color: Colors.red,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final authService = ref.watch(authServiceProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Home',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: StreamBuilder<User?>(
        stream: authService.userChanges,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          final user = snapshot.data;

          if (user != null && user.emailVerified) {
            return const DashboardPage();
          }

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
