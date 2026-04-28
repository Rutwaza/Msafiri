class AppConstants {
  // App Info
  static const String appName = 'Spotlight';
  static const String appVersion = '1.0.0';

  // Storage Keys
  static const String tokenKey = 'auth_token';
  static const String userKey = 'user_data';
  static const String localeKey = 'app_locale';
  static const String themeKey = 'app_theme';

  // API Constants
  static const int receiveTimeout = 15000;
  static const int connectTimeout = 15000;
  static const int sendTimeout = 15000;

  // Billing guard: pause Google Maps widget rendering temporarily.
  // Set to false to restore native Google Maps.
  static const bool pauseGoogleMaps = false;

  // Pagination
  static const int defaultPageSize = 10;
  static const int maxImageSize = 5 * 1024 * 1024; // 5MB

  // Validation
  static const int minPasswordLength = 6;
  static const int maxBusinessNameLength = 100;
  static const int maxDescriptionLength = 1000;
}

class AppRoutes {
  static const String splash = '/';
  static const String login = '/login';
  static const String register = '/register';
  static const String onboarding = '/onboarding';
  static const String trafficManagement = '/traffic-management';
  static const String adminDashboard = '/admin-dashboard';
}

class AppAssets {
  // Images
  static const String logo = 'assets/images/logo.png';
  static const String onboarding1 = 'assets/images/onboarding1.png';
  static const String onboarding2 = 'assets/images/onboarding2.png';
  static const String onboarding3 = 'assets/images/onboarding3.png';
  static const String placeholder = 'assets/images/placeholder.png';

  // Icons
  static const String google = 'assets/icons/google.svg';
  static const String apple = 'assets/icons/apple.svg';
  static const String facebook = 'assets/icons/facebook.svg';

  // Animations
  static const String loading = 'assets/animations/loading.json';
  static const String success = 'assets/animations/success.json';
  static const String empty = 'assets/animations/empty.json';
}
