import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
// Import the optimized dashboard file that now exports:
//   - themeModeProvider
//   - lightTheme
//   - darkTheme
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';

const String appVersion = '1.0.28';

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

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    // 🔥 Force a rebuild when themeMode changes by using a Key.
    return MaterialApp(
      key: ValueKey(themeMode),
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: const DashboardPage(),
      routes: {
        '/provision': (context) => const ProvisionPage(),
        '/wifiConfig': (context) => const WifiConfigPage(),
      },
    );
  }
}
