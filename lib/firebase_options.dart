import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'FirebaseOptions are not configured for web in spotlight_traffic_app yet.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'FirebaseOptions are not configured for iOS in spotlight_traffic_app yet.',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'FirebaseOptions are not configured for macOS in spotlight_traffic_app yet.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'FirebaseOptions are not configured for Windows in spotlight_traffic_app yet.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'FirebaseOptions are not configured for Linux in spotlight_traffic_app yet.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB1n7QDTRRx5o2Vjac3IWx04WF0YtvJEcc',
    appId: '1:450569911476:android:b3012cdd8e7bba9f882be1',
    messagingSenderId: '450569911476',
    projectId: 'spotlight-traffic-prod',
    storageBucket: 'spotlight-traffic-prod.firebasestorage.app',
  );

}
