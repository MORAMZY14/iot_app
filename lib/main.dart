import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';      // <-- import your WiFi config page
// If you also have WifiSetupPage, import it too

const String appVersion = '1.0.13';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Home',
      theme: ThemeData(useMaterial3: true),
      home: const DashboardPage(),
      routes: {
        '/provision': (context) => const ProvisionPage(),     // ✅ replaced
        '/wifiConfig': (context) => const WifiConfigPage(),   // ✅ replaced
        // If you have a separate setup page:
        // '/wifiSetup': (context) => const WifiSetupPage(),
      },
    );
  }
}