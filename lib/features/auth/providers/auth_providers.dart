import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/traffic_auth_service.dart';
import '../domain/traffic_user_profile.dart';

final trafficAuthServiceProvider = Provider<TrafficAuthService>((ref) {
  return TrafficAuthService();
});

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

final trafficUserProfileProvider = StreamProvider<TrafficUserProfile?>((ref) {
  return ref.watch(trafficAuthServiceProvider).watchMyProfile();
});
