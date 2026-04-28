import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:spotlight_traffic_app/firebase_options.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FirebaseFirestore _fs = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'msafiri_alerts';
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    _channelId,
    'Msafiri Alerts',
    description: 'Ride, card, and booking alerts',
    importance: Importance.high,
  );

  static StreamSubscription<User?>? _authSub;
  static StreamSubscription<String>? _tokenSub;
  static StreamSubscription<RemoteMessage>? _msgSub;
  static StreamSubscription<RemoteMessage>? _openSub;
  static bool _initialized = false;
  static String? _lastUid;
  static String? _lastToken;

  static Future<void> dispose() async {
    await _authSub?.cancel();
    await _tokenSub?.cancel();
    await _msgSub?.cancel();
    await _openSub?.cancel();
    _authSub = null;
    _tokenSub = null;
    _msgSub = null;
    _openSub = null;
    _initialized = false;
  }

  static Future<void> initialize({
    required Future<void> Function(Map<String, dynamic> data) onOpenData,
  }) async {
    if (_initialized) return;
    _initialized = true;

    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) async {
        final payload = resp.payload;
        if (payload == null || payload.trim().isEmpty) return;
        try {
          final data = jsonDecode(payload);
          if (data is Map) {
            await onOpenData(
              data.map((k, v) => MapEntry('$k', v)),
            );
          }
        } catch (_) {}
      },
    );

    final android = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_channel);

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: false,
      provisional: false,
      criticalAlert: false,
      carPlay: false,
    );

    final token = await _messaging.getToken();
    if (token != null && token.trim().isNotEmpty) {
      _lastToken = token.trim();
      await _attachTokenToCurrentUser(_lastToken!);
    }

    _tokenSub = _messaging.onTokenRefresh.listen((token) async {
      final next = token.trim();
      if (next.isEmpty) return;
      _lastToken = next;
      await _attachTokenToCurrentUser(next);
    });

    _authSub = _auth.authStateChanges().listen((user) async {
      final nextUid = user?.uid;
      final tokenNow = _lastToken ?? (await _messaging.getToken());
      final safeToken = (tokenNow ?? '').trim();
      if (_lastUid != null &&
          _lastUid!.isNotEmpty &&
          _lastUid != nextUid &&
          safeToken.isNotEmpty) {
        await _detachTokenFromUser(_lastUid!, safeToken);
      }
      _lastUid = nextUid;
      if (nextUid != null && safeToken.isNotEmpty) {
        await _attachTokenToCurrentUser(safeToken);
      }
    });

    _msgSub = FirebaseMessaging.onMessage.listen((m) async {
      final title = m.notification?.title ?? '${m.data['title'] ?? 'Msafiri'}';
      final body = m.notification?.body ?? '${m.data['body'] ?? ''}';
      await _local.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Msafiri Alerts',
            channelDescription: 'Ride, card, and booking alerts',
            importance: Importance.max,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: jsonEncode(m.data),
      );
    });

    _openSub = FirebaseMessaging.onMessageOpenedApp.listen((m) async {
      await onOpenData(m.data);
    });

    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      await onOpenData(initial.data);
    }
  }

  static Future<void> _attachTokenToCurrentUser(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    await _fs.collection('traffic_users').doc(uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> _detachTokenFromUser(String uid, String token) async {
    await _fs.collection('traffic_users').doc(uid).set({
      'fcmTokens': FieldValue.arrayRemove([token]),
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
