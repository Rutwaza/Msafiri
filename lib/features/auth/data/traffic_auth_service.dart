import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:spotlight_traffic_app/core/constants/firestore_collections.dart';

import '../domain/traffic_user_profile.dart';

class TrafficAuthService {
  TrafficAuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  static const String superAdminEmail = 'nelsonjembe99@gmail.com';

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Future<TrafficUserProfile?> getCurrentProfile() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final doc = await _firestore
        .collection(FsCollections.trafficUsers)
        .doc(user.uid)
        .get();
    if (!doc.exists) return null;
    return TrafficUserProfile.fromDoc(doc);
  }

  Stream<TrafficUserProfile?> watchMyProfile() {
    return _auth.authStateChanges().asyncExpand((user) {
      if (user == null) {
        return Stream.value(null);
      }
      return _firestore
          .collection(FsCollections.trafficUsers)
          .doc(user.uid)
          .snapshots()
          .map((doc) => doc.exists ? TrafficUserProfile.fromDoc(doc) : null);
    });
  }

  Future<TrafficUserProfile> ensureTrafficUserProfile(
    User user, {
    String? displayName,
    String? email,
    String? phone,
    bool isNewAccount = false,
  }) async {
    final docRef =
        _firestore.collection(FsCollections.trafficUsers).doc(user.uid);
    final memberRef =
        _firestore.collection(FsCollections.agencyMembers).doc(user.uid);
    final emailValue = (email ?? user.email ?? '').trim();
    final emailLower = emailValue.toLowerCase();

    final memberDoc = await memberRef.get();
    final roleInfo = _resolveRole(user: user, memberDoc: memberDoc);

    final existing = await docRef.get();
    final now = FieldValue.serverTimestamp();

    if (!existing.exists) {
      await docRef.set({
        'uid': user.uid,
        'email': emailValue,
        'emailLower': emailLower,
        'displayName': (displayName ?? user.displayName ?? '').trim(),
        'phone': (phone ?? user.phoneNumber ?? '').trim(),
        'role': TrafficUserProfile.roleToString(roleInfo.role),
        'status': 'active',
        'agencyId': roleInfo.agencyId,
        'onboarding': {
          'completed': !isNewAccount,
          'step': isNewAccount ? 'profile' : 'done',
          'completedAt': isNewAccount ? null : now,
        },
        'createdAt': now,
        'updatedAt': now,
        'lastLoginAt': now,
      }, SetOptions(merge: true));
    } else {
      await docRef.set({
        if (emailValue.isNotEmpty) 'email': emailValue,
        if (emailLower.isNotEmpty) 'emailLower': emailLower,
        if ((displayName ?? user.displayName ?? '').trim().isNotEmpty)
          'displayName': (displayName ?? user.displayName ?? '').trim(),
        if ((phone ?? user.phoneNumber ?? '').trim().isNotEmpty)
          'phone': (phone ?? user.phoneNumber ?? '').trim(),
        'role': TrafficUserProfile.roleToString(roleInfo.role),
        'agencyId': roleInfo.agencyId,
        if (isNewAccount) 'onboarding': {'completed': false, 'step': 'profile'},
        'lastLoginAt': now,
        'updatedAt': now,
      }, SetOptions(merge: true));
    }

    final finalDoc = await docRef.get();
    return TrafficUserProfile.fromDoc(finalDoc);
  }

  Future<TrafficUserProfile> completeOnboarding({
    required String displayName,
    String? phone,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'unauthenticated',
        message: 'Sign in required.',
      );
    }

    final profile = await ensureTrafficUserProfile(
      user,
      displayName: displayName,
      phone: phone,
    );

    final docRef =
        _firestore.collection(FsCollections.trafficUsers).doc(user.uid);
    await docRef.set({
      'displayName': displayName.trim(),
      if ((phone ?? '').trim().isNotEmpty) 'phone': phone!.trim(),
      'onboarding': {
        'completed': true,
        'completedAt': FieldValue.serverTimestamp(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final updatedDoc = await docRef.get();
    return updatedDoc.exists ? TrafficUserProfile.fromDoc(updatedDoc) : profile;
  }

  _RoleInfo _resolveRole({
    required User user,
    required DocumentSnapshot<Map<String, dynamic>> memberDoc,
  }) {
    final email = (user.email ?? '').trim().toLowerCase();
    if (email == superAdminEmail) {
      return const _RoleInfo(role: TrafficUserRole.superAdmin, agencyId: null);
    }

    if (!memberDoc.exists) {
      return const _RoleInfo(role: TrafficUserRole.rider, agencyId: null);
    }

    final data = memberDoc.data() ?? const <String, dynamic>{};
    if (data['active'] == false) {
      return const _RoleInfo(role: TrafficUserRole.rider, agencyId: null);
    }

    final role =
        TrafficUserProfile.roleFromString('${data['role'] ?? 'rider'}');
    final agencyId = (data['agencyId'] ?? '').toString().trim();

    return _RoleInfo(
      role: role,
      agencyId: agencyId.isEmpty ? null : agencyId,
    );
  }
}

class _RoleInfo {
  const _RoleInfo({
    required this.role,
    required this.agencyId,
  });

  final TrafficUserRole role;
  final String? agencyId;
}
