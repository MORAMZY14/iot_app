import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String databaseUrl = 'https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app';

  User? get currentUser => _auth.currentUser;
  Stream<User?> get userChanges => _auth.authStateChanges();

  Future<User?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
    required String esp32Code,
  }) async {
    try {
      print('🔍 Verifying ESP32 Code: $esp32Code');

      final response = await http.get(
        Uri.parse('$databaseUrl/esp_public/$esp32Code/status.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw 'ESP32 not found. Please check the code and try again.';
      }

      final espData = jsonDecode(response.body);
      if (espData == null || espData['ip'] == null) {
        throw 'ESP32 is offline or not broadcasting. Please ensure your ESP32 is powered on.';
      }

      print('✅ ESP32 Verified! IP: ${espData['ip']}');

      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      User? user = result.user;

      if (user != null) {
        await user.updateDisplayName(displayName);
        await user.sendEmailVerification();

        await _firestore.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': email,
          'displayName': displayName,
          'esp32Code': esp32Code,
          'createdAt': FieldValue.serverTimestamp(),
          'emailVerified': false,
        });

        print('📝 Writing ownerUID to ESP public node...');

        final claimResponse = await http.put(
          Uri.parse('$databaseUrl/esp_public/$esp32Code/ownerUID.json'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(user.uid),
        ).timeout(const Duration(seconds: 5));

        if (claimResponse.statusCode == 200) {
          print('✅ ESP claimed successfully!');
        } else {
          print('⚠️ Failed to claim ESP: ${claimResponse.statusCode}');
        }

        return user;
      }
      return null;
    } on FirebaseAuthException catch (e) {
      print('🔥 Registration error: ${e.message}');
      rethrow;
    } catch (e) {
      print('🔥 Registration error: $e');
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
      print('Sign in error: ${e.message}');
      rethrow;
    } catch (e) {
      print('Sign in error: $e');
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
      print('Password reset error: ${e.message}');
      rethrow;
    }
  }

  Future<void> resendVerificationEmail() async {
    User? user = _auth.currentUser;
    if (user != null && !user.emailVerified) {
      await user.sendEmailVerification();
    }
  }

  Future<Map<String, dynamic>?> getUserData(String uid) async {
    try {
      DocumentSnapshot doc = await _firestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      if (doc.exists) {
        return doc.data() as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('Error getting user data: $e');
      return null;
    }
  }

  Future<void> updateEsp32Code(String uid, String newCode) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'esp32Code': newCode,
      });
    } catch (e) {
      print('Error updating ESP32 Code: $e');
      rethrow;
    }
  }

  Future<String?> getUserEsp32Code(String uid) async {
    try {
      DocumentSnapshot doc = await _firestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return data['esp32Code'] as String?;
      }
      return null;
    } catch (e) {
      print('Error getting ESP32 Code: $e');
      return null;
    }
  }

  Future<void> deleteAccount() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        await _firestore.collection('users').doc(user.uid).delete();
        await user.delete();
      }
    } catch (e) {
      print('Error deleting account: $e');
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