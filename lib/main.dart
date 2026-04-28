import 'dart:ui';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:spotlight_traffic_app/core/constants/app_constants.dart';
import 'package:spotlight_traffic_app/core/services/push_notification_service.dart';
import 'package:spotlight_traffic_app/firebase_options.dart';
import 'package:spotlight_traffic_app/presentation/pages/admin/admin_dashboard_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/auth/login_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/auth/register_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/home/home_shell_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/onboarding/onboarding_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught zone error: $error');
    debugPrintStack(stackTrace: stack);
    return false;
  };

  runApp(const ProviderScope(child: SpotLightTrafficApp()));
}

class SpotLightTrafficApp extends StatefulWidget {
  const SpotLightTrafficApp({super.key});

  @override
  State<SpotLightTrafficApp> createState() => _SpotLightTrafficAppState();
}

class _SpotLightTrafficAppState extends State<SpotLightTrafficApp> {
  late Future<void> _firebaseInitFuture;
  bool _pushInitDone = false;

  @override
  void initState() {
    super.initState();
    _firebaseInitFuture = _initFirebase();
  }

  late final GoRouter _router = GoRouter(
    initialLocation: AppRoutes.splash,
    redirect: (context, state) {
      final user = FirebaseAuth.instance.currentUser;
      final location = state.matchedLocation;
      final isAuthPath =
          location == AppRoutes.login || location == AppRoutes.register;

      if (user == null) {
        return isAuthPath ? null : AppRoutes.login;
      }

      if (location == AppRoutes.splash || isAuthPath) {
        return AppRoutes.trafficManagement;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterPage(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingPage(),
      ),
      GoRoute(
        path: AppRoutes.trafficManagement,
        builder: (context, state) => HomeShellPage(
          initialBusId: state.uri.queryParameters['busId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.adminDashboard,
        builder: (context, state) => const AdminDashboardPage(),
      ),
    ],
  );

  Future<void> _initFirebase() async {
    if (Firebase.apps.isNotEmpty) {
      if (!_pushInitDone) {
        _pushInitDone = true;
        await PushNotificationService.initialize(
          onOpenData: _handlePushOpenData,
        );
      }
      return;
    }
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (!_pushInitDone) {
      _pushInitDone = true;
      await PushNotificationService.initialize(
        onOpenData: _handlePushOpenData,
      );
    }
  }

  Future<void> _handlePushOpenData(Map<String, dynamic> data) async {
    final rawBusId = '${data['busId'] ?? ''}'.trim();
    if (rawBusId.isNotEmpty) {
      _router.go('${AppRoutes.trafficManagement}?busId=$rawBusId');
      return;
    }
    _router.go(AppRoutes.trafficManagement);
  }

  void _retryBootstrap() {
    setState(() {
      _firebaseInitFuture = _initFirebase();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _firebaseInitFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: _BootstrapLoading(),
          );
        }
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: _BootstrapError(
              error: snapshot.error.toString(),
              onRetry: _retryBootstrap,
            ),
          );
        }
        return MaterialApp.router(
          title: 'msafiri',
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          routerConfig: _router,
        );
      },
    );
  }
}

class _BootstrapLoading extends StatelessWidget {
  const _BootstrapLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class _BootstrapError extends StatelessWidget {
  const _BootstrapError({
    required this.error,
    required this.onRetry,
  });

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.orange, size: 42),
              const SizedBox(height: 10),
              const Text(
                'Startup failed',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
