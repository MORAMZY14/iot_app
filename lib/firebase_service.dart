import 'package:firebase_database/firebase_database.dart';

class FirebaseService {
  // Singleton pattern
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  late final DatabaseReference _database;
  bool _isInitialized = false;

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      _database = FirebaseDatabase.instance.ref();
      _isInitialized = true;
    }
  }

  // Get the entire smartHome node
  Stream<DatabaseEvent> getData() async* {
    await _ensureInitialized();
    yield* _database.child('smartHome').onValue;
  }

  // Set room light status
  Future<void> setRoomLight(String room, bool value) async {
    try {
      await _ensureInitialized();
      await _database
          .child('smartHome')
          .child('lights')
          .child(room)
          .set(value);
      print('✓ Room $room set to $value');
    } catch (e) {
      print('✗ Error setting room light: $e');
      rethrow;
    }
  }
}