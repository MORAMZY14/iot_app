import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';
import 'io_modules_page.dart';
import 'splash_screen.dart';  // 🔥 NEW: Import your splash screen
import 'login_screen.dart';
import 'app_constants.dart';

const String appVersion = 'V2.0.5';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Run the Flutter UI immediately. Firebase is initialized by the providers
  // while the SplashScreen is already visible, so the user no longer sees a
  // blank white screen while Firebase starts.
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );

  unawaited(_requestMobilePermissions());
}

Future<void> _requestMobilePermissions() async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
  try {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  } catch (e) {
    debugPrint('Permission request skipped: $e');
  }
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
        '/ioModules': (context) => const IoModulesPage(),
      },
    );
  }
}
