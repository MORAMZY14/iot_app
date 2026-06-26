import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Stream of user changes
  Stream<User?> get userChanges => _auth.authStateChanges();

  // Register with email and password
  Future<User?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
    required String esp32Ip,
  }) async {
    try {
      // Create user with email and password
      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      User? user = result.user;

      if (user != null) {
        // Update display name
        await user.updateDisplayName(displayName);

        // Send email verification
        await user.sendEmailVerification();

        // Save user data to Firestore with ESP32 IP
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
      print('Registration error: ${e.message}');
      rethrow;
    } catch (e) {
      print('Registration error: $e');
      rethrow;
    }
  }

  // Sign in with email and password
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

      // Check if email is verified
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

  // Sign out
  Future<void> signOut() async {
    await _auth.signOut();
  }

  // Reset password
  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      print('Password reset error: ${e.message}');
      rethrow;
    }
  }

  // Resend verification email
  Future<void> resendVerificationEmail() async {
    User? user = _auth.currentUser;
    if (user != null && !user.emailVerified) {
      await user.sendEmailVerification();
    }
  }

  // Get user data from Firestore
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

  // Update ESP32 IP
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

  // Get user's ESP32 IP
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

  // Delete user account
  Future<void> deleteAccount() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        // Delete user data from Firestore
        await _firestore.collection('users').doc(user.uid).delete();
        // Delete the auth account
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