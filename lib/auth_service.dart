import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get userChanges => _auth.authStateChanges();

  Future<User?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
    required String esp32Ip,
  }) async {
    try {
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
          'esp32Ip': esp32Ip,
          'createdAt': FieldValue.serverTimestamp(),
          'emailVerified': false,
        });
        return user;
      }
      return null;
    } on FirebaseAuthException catch (e) {
      // 🔥 FIX: Print the exact Firebase error
      print('🔥 Firebase Registration Error: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      // 🔥 FIX: Print the generic error
      print('🔥 Generic Registration Error: $e');
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
      // 🔥 FIX: Print the exact Firebase error
      print('🔥 Firebase Sign-in Error: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      // 🔥 FIX: Print the generic error
      print('🔥 Generic Sign-in Error: $e');
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
      print('Firebase Password Reset Error: ${e.code} - ${e.message}');
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
      DocumentSnapshot doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        return doc.data() as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('Error getting user data: $e');
      return null;
    }
  }

  Future<void> updateEsp32Ip(String uid, String newIp) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'esp32Ip': newIp,
      });
    } catch (e) {
      print('Error updating ESP32 IP: $e');
      rethrow;
    }
  }

  Future<String?> getUserEsp32Ip(String uid) async {
    try {
      DocumentSnapshot doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return data['esp32Ip'] as String?;
      }
      return null;
    } catch (e) {
      print('Error getting ESP32 IP: $e');
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

// Auth service provider
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

// User data provider
final userDataProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final authService = ref.watch(authServiceProvider);
  final user = authService.currentUser;
  if (user != null) {
    return await authService.getUserData(user.uid);
  }
  return null;
});

// User ESP32 IP provider
final userEsp32IpProvider = FutureProvider<String?>((ref) async {
  final authService = ref.watch(authServiceProvider);
  final user = authService.currentUser;
  if (user != null) {
    return await authService.getUserEsp32Ip(user.uid);
  }
  return null;
});