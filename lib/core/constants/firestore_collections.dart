class FsCollections {
  const FsCollections._();

  static const String trafficUsers = 'traffic_users';
  static const String agencyMembers = 'agency_members';
  static const String agencies = 'agencies';
  static const String buses = 'buses';
  static const String routes = 'routes';
  static const String cards = 'cards';
  static const String bookings = 'bookings';
  static const String cardTransactions = 'card_transactions';
  static const String adminEvents = 'admin_events';
  static const String directionRequests = 'direction_requests';
  static const String agencyApplications = 'agency_applications';
  static const String agencyPasswordResetRequests =
      'agency_password_reset_requests';

  // Temporary compatibility while legacy reads are being migrated.
  static const String legacyUsers = 'users';
}

class FsEnums {
  const FsEnums._();

  static const List<String> trafficUserRoles = [
    'rider',
    'agency_staff',
    'agency_admin',
    'super_admin',
  ];

  static const List<String> trafficUserStatuses = [
    'pending',
    'active',
    'suspended',
    'disabled',
  ];

  static const List<String> bookingStatuses = [
    'booked',
    'paid',
    'expired',
    'cancelled',
    'released',
  ];
}
