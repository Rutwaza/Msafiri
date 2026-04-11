class RtdbContract {
  const RtdbContract._();

  static const String dbUrl =
      'https://spotlight-traffic-prod-default-rtdb.firebaseio.com';

  static const String devicesPath = 'devices';

  // Optional normalized structure keys.
  static const String metaKey = 'meta';
  static const String latestKey = 'latest';
  static const String historyKey = 'history';
}
