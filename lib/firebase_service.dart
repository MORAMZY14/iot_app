import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'app_logger.dart';

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
          final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      yield* _database.child('smartHome').child(uid).onValue;
  }

  // Set room light status
  Future<void> setRoomLight(String room, bool value) async {
    try {
      await _ensureInitialized();
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        throw StateError('User is not authenticated');
      }
      await _database
          .child('smartHome')
          .child(uid)
          .child('lights')
          .child(room)
          .set(value);
      logDebug('✓ Room $room set to $value');
    } catch (e) {
      logDebug('✗ Error setting room light: $e');
      rethrow;
    }
  }
}
