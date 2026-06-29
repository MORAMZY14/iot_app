import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';
import 'splash_screen.dart';  // 🔥 NEW: Import your splash screen
import 'login_screen.dart';
import 'app_constants.dart';

const String appVersion = '1.0.52';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    debugPrint("✅ Firebase initialized successfully");
  } catch (e, stackTrace) {
    debugPrint("❌ Firebase initialization failed");
    debugPrint(e.toString());
    debugPrintStack(stackTrace: stackTrace);

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
    return;
  }

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,

      // 🔥 NEW: Start with SplashScreen instead of StreamBuilder
      home: const SplashScreen(),

      routes: {
        '/login': (context) => const LoginScreen(),
        '/provision': (context) => const ProvisionPage(),
        '/wifiConfig': (context) => const WifiConfigPage(),
      },
    );
  }
}
