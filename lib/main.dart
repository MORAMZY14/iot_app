import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
// Import the optimized dashboard file that now exports:
//   - themeModeProvider
//   - lightTheme
//   - darkTheme
import 'dashboard_page.dart';
import 'provisioning_page.dart';
import 'wifi_config_page.dart';
import 'auth_service.dart';
import 'login_screen.dart';

const String appVersion = '1.0.30';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

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

    // 🔥 Force a rebuild when themeMode changes by using a Key.
    return MaterialApp(
      key: ValueKey(themeMode),
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: StreamBuilder<User?>(
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
          // Loading state
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: Color(0xFF6C63FF),
              ),
            ),
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
