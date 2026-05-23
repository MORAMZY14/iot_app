import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dashboard_page.dart';


const String appVersion = '1.0.10';

void main() {
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
        '/provision': (context) => const Placeholder(),
        '/wifiConfig': (context) => const Placeholder(),
      },
    );
  }
}