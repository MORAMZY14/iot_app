class AppConfig {
  static const String databaseUrl =
      'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app';
  static const String esp32ApBaseUrl = 'http://192.168.4.1';
  static const String fallbackEsp32Ip = '192.168.1.9';
  static const String appVersion = '1.0.36';

  // Low-latency control path timings. Local Wi-Fi/BLE should fail fast so the
  // app can fall back to Firebase without making the button feel frozen.
  static const Duration instantTimeout = Duration(milliseconds: 450);
  static const Duration bleControlTimeout = Duration(milliseconds: 650);
  static const Duration localControlTimeout = Duration(milliseconds: 450);
  static const Duration firebaseControlTimeout = Duration(milliseconds: 2500);

  static const Duration shortTimeout = Duration(milliseconds: 1200);
  static const Duration mediumTimeout = Duration(milliseconds: 2500);
  static const Duration longTimeout = Duration(seconds: 8);
}
