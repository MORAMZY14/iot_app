import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_logger.dart';
import 'app_constants.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final String databaseUrl = AppConfig.databaseUrl;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get userChanges => _auth.authStateChanges();

  Future<User?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
    required String esp32Code,
  }) async {
    try {
      logDebug('🔍 Verifying ESP32 Code: $esp32Code');

      final response = await http.get(
        Uri.parse('$databaseUrl/esp_public/$esp32Code/status.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(AppConfig.mediumTimeout);

      if (response.statusCode != 200) {
        throw 'ESP32 not found. Please check the code and try again.';
      }

      final espData = jsonDecode(response.body);
      if (espData == null || espData['ip'] == null) {
        throw 'ESP32 is offline or not broadcasting. Please ensure your ESP32 is powered on.';
      }

      logDebug('✅ ESP32 Verified! IP: ${espData['ip']}');

      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      User? user = result.user;

      if (user != null) {
        await user.updateDisplayName(displayName);
        await user.sendEmailVerification();

        // 🔥 FIX: Write user data to Realtime Database, NOT Firestore
        final userData = {
          'uid': user.uid,
          'email': email,
          'displayName': displayName,
          'esp32Code': esp32Code,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'emailVerified': false,
        };

        final userResponse = await http.put(
          Uri.parse('$databaseUrl/users/${user.uid}.json'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(userData),
        ).timeout(AppConfig.mediumTimeout);

        if (userResponse.statusCode != 200) {
          throw Exception('Failed to create user in Realtime Database');
        }

        logDebug('📝 Writing ownerUID to ESP public node...');

        final claimResponse = await http.put(
          Uri.parse('$databaseUrl/esp_public/$esp32Code/ownerUID.json'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(user.uid),
        ).timeout(AppConfig.mediumTimeout);

        if (claimResponse.statusCode == 200) {
          logDebug('✅ ESP claimed successfully!');
        } else {
          logDebug('⚠️ Failed to claim ESP: ${claimResponse.statusCode}');
        }

        return user;
      }
      return null;
    } on FirebaseAuthException catch (e) {
      logDebug('🔥 Registration error: ${e.message}');
      rethrow;
    } catch (e) {
      logDebug('🔥 Registration error: $e');
      rethrow;
    }
  }

  Future<User?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      User? user = result.user;
      if (user != null && !user.emailVerified) {
        await _auth.signOut();
        throw 'Please verify your email before signing in. Check your inbox.';
      }
      return user;
    } on FirebaseAuthException catch (e) {
      logDebug('Sign in error: ${e.message}');
      rethrow;
    } catch (e) {
      logDebug('Sign in error: $e');
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      logDebug('Password reset error: ${e.message}');
      rethrow;
    }
  }

  Future<void> resendVerificationEmail() async {
    User? user = _auth.currentUser;
    if (user != null && !user.emailVerified) {
      await user.sendEmailVerification();
    }
  }

  // 🔥 FIX: Read user data from Realtime Database
  Future<Map<String, dynamic>?> getUserData(String uid) async {
    try {
      final response = await http.get(
        Uri.parse('$databaseUrl/users/$uid.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(AppConfig.shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      logDebug('Error getting user data: $e');
      return null;
    }
  }

  // 🔥 FIX: Update ESP32 Code in Realtime Database
  Future<void> updateEsp32Code(String uid, String newCode) async {
    try {
      final response = await http.patch(
        Uri.parse('$databaseUrl/users/$uid.json'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'esp32Code': newCode}),
      ).timeout(AppConfig.mediumTimeout);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      logDebug('Error updating ESP32 Code: $e');
      rethrow;
    }
  }

  // 🔥 FIX: Read ESP32 Code from Realtime Database
  Future<String?> getUserEsp32Code(String uid) async {
    try {
      final response = await http.get(
        Uri.parse('$databaseUrl/users/$uid/esp32Code.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(AppConfig.shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data as String?;
      }
      return null;
    } catch (e) {
      logDebug('Error getting ESP32 Code: $e');
      return null;
    }
  }

  Future<void> deleteAccount() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        // 🔥 FIX: Delete user from Realtime Database
        await http.delete(
          Uri.parse('$databaseUrl/users/${user.uid}.json'),
        ).timeout(AppConfig.shortTimeout);
        await user.delete();
      }
    } catch (e) {
      logDebug('Error deleting account: $e');
      rethrow;
    }
  }
}

// 🔥 PROVIDERS
final authServiceProvider = FutureProvider<AuthService>((ref) async {
  return AuthService();
});

final userDataProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;
  if (user != null) {
    return await authService.getUserData(user.uid);
  }
  return null;
});

final userEsp32CodeProvider = FutureProvider<String?>((ref) async {
  final authService = await ref.watch(authServiceProvider.future);
  final user = authService.currentUser;
  if (user != null) {
    return await authService.getUserEsp32Code(user.uid);
  }
  return null;
});
