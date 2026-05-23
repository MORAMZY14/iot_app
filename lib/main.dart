import 'package:flutter/material.dart';

 const String appVersion = '1.0.8'; 

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('iOS Test'),
        ),
        body: const Center(
          child: Text(
            'App Started Successfully',
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}
