class AppConfig {
  static const String databaseUrl =
      'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app';
  static const String esp32ApBaseUrl = 'http://192.168.4.1';
  static const String appVersion = '1.0.32';

  static const Duration shortTimeout = Duration(seconds: 3);
  static const Duration mediumTimeout = Duration(seconds: 5);
  static const Duration longTimeout = Duration(seconds: 10);
}
