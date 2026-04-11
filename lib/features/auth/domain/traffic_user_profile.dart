import 'package:cloud_firestore/cloud_firestore.dart';

enum TrafficUserRole {
  rider,
  agencyStaff,
  agencyAdmin,
  superAdmin,
}

enum TrafficUserStatus {
  pending,
  active,
  suspended,
  disabled,
}

class TrafficUserProfile {
  const TrafficUserProfile({
    required this.uid,
    required this.email,
    required this.emailLower,
    required this.displayName,
    required this.phone,
    required this.role,
    required this.status,
    required this.onboardingCompleted,
    required this.createdAt,
    required this.updatedAt,
    required this.lastLoginAt,
    this.agencyId,
  });

  final String uid;
  final String email;
  final String emailLower;
  final String displayName;
  final String phone;
  final TrafficUserRole role;
  final TrafficUserStatus status;
  final bool onboardingCompleted;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastLoginAt;
  final String? agencyId;

  bool get isActive => status == TrafficUserStatus.active;

  bool get canAccessAdminConsole =>
      role == TrafficUserRole.agencyAdmin ||
      role == TrafficUserRole.agencyStaff ||
      role == TrafficUserRole.superAdmin;

  static TrafficUserRole roleFromString(String value) {
    switch (value) {
      case 'agency_staff':
        return TrafficUserRole.agencyStaff;
      case 'agency_admin':
        return TrafficUserRole.agencyAdmin;
      case 'super_admin':
        return TrafficUserRole.superAdmin;
      case 'rider':
      default:
        return TrafficUserRole.rider;
    }
  }

  static String roleToString(TrafficUserRole role) {
    switch (role) {
      case TrafficUserRole.agencyStaff:
        return 'agency_staff';
      case TrafficUserRole.agencyAdmin:
        return 'agency_admin';
      case TrafficUserRole.superAdmin:
        return 'super_admin';
      case TrafficUserRole.rider:
        return 'rider';
    }
  }

  static TrafficUserStatus statusFromString(String value) {
    switch (value) {
      case 'active':
        return TrafficUserStatus.active;
      case 'suspended':
        return TrafficUserStatus.suspended;
      case 'disabled':
        return TrafficUserStatus.disabled;
      case 'pending':
      default:
        return TrafficUserStatus.pending;
    }
  }

  static String statusToString(TrafficUserStatus status) {
    switch (status) {
      case TrafficUserStatus.active:
        return 'active';
      case TrafficUserStatus.suspended:
        return 'suspended';
      case TrafficUserStatus.disabled:
        return 'disabled';
      case TrafficUserStatus.pending:
        return 'pending';
    }
  }

  factory TrafficUserProfile.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    DateTime? castTs(dynamic value) {
      if (value is Timestamp) return value.toDate();
      return null;
    }

    final onboarding =
        Map<String, dynamic>.from(data['onboarding'] as Map? ?? const {});

    return TrafficUserProfile(
      uid: doc.id,
      email: '${data['email'] ?? ''}',
      emailLower: '${data['emailLower'] ?? ''}',
      displayName: '${data['displayName'] ?? ''}',
      phone: '${data['phone'] ?? ''}',
      role: roleFromString('${data['role'] ?? 'rider'}'),
      status: statusFromString('${data['status'] ?? 'pending'}'),
      onboardingCompleted: onboarding['completed'] == true,
      createdAt: castTs(data['createdAt']),
      updatedAt: castTs(data['updatedAt']),
      lastLoginAt: castTs(data['lastLoginAt']),
      agencyId: data['agencyId'] == null ? null : '${data['agencyId']}',
    );
  }
}
