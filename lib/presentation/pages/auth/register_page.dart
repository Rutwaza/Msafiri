import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:country_code_picker/country_code_picker.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/spotlight_toast.dart';
import '../../../features/auth/data/traffic_auth_service.dart';
import '../../../features/auth/domain/traffic_user_profile.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _authService = TrafficAuthService();
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final email = _emailController.text.trim().toLowerCase();
        final username = _usernameController.text.trim().toLowerCase();

        UserCredential userCredential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: _passwordController.text.trim(),
        );

        if (userCredential.user != null) {
          try {
            final profile = await _ensureUserDocument(
              userCredential.user!,
              name: username,
              email: email,
            );
            _goAfterAuth(profile);
          } catch (_) {
            if (mounted) {
              context.go(AppRoutes.onboarding);
            }
          }
        }

        try {
          await userCredential.user?.sendEmailVerification();
        } catch (_) {}

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      } on FirebaseAuthException catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }

        showSpotlightToast(context, _friendlyAuthError(e), success: false);
      } catch (e) {
        if (_isPigeonUserDetailsCastError(e)) {
          final recovered = await _recoverFromKnownAuthCastIssue();
          if (recovered) return;
        }
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          showSpotlightToast(
            context,
            'Registration failed: ${e.toString()}',
            success: false,
          );
        }
      }
    }
  }

  bool _isPigeonUserDetailsCastError(Object error) {
    final raw = error.toString();
    return raw.contains("PigeonUserDetails") &&
        raw.contains("List<Object?>") &&
        raw.contains("type cast");
  }

  Future<bool> _recoverFromKnownAuthCastIssue() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    TrafficUserProfile? profile;
    try {
      profile = await _ensureUserDocument(
        user,
        name: _usernameController.text.trim().toLowerCase(),
        email: user.email ?? _emailController.text.trim().toLowerCase(),
      );
    } catch (_) {}

    if (!mounted) return true;
    setState(() {
      _isLoading = false;
    });

    if (profile != null) {
      _goAfterAuth(profile);
    } else {
      context.go(AppRoutes.onboarding);
    }
    return true;
  }

  Future<TrafficUserProfile> _ensureUserDocument(
    User user, {
    String? name,
    String? email,
    String? phone,
  }) {
    return _authService.ensureTrafficUserProfile(
      user,
      displayName: name,
      email: email,
      phone: phone,
    );
  }

  void _goAfterAuth(TrafficUserProfile profile) {
    if (!mounted) return;
    context.go(
      profile.onboardingCompleted
          ? AppRoutes.trafficManagement
          : AppRoutes.onboarding,
    );
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    final code = e.code.toLowerCase();
    if (code == 'weak-password') {
      return 'Password is too weak. Use at least 6 characters.';
    }
    if (code == 'email-already-in-use') {
      return 'An account already exists with this email.';
    }
    if (code == 'invalid-email') return 'Invalid email address.';
    if (code == 'operation-not-allowed') {
      return 'Email/password auth is disabled in Firebase project.';
    }
    if (code == 'network-request-failed') {
      return 'Network error. Check connection and retry.';
    }
    if (code == 'too-many-requests') {
      return 'Too many attempts. Please wait and try again.';
    }
    return e.message?.trim().isNotEmpty == true
        ? e.message!.trim()
        : 'Sign up failed. Please try again.';
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;
      if (user != null) {
        final profile = await _ensureUserDocument(
          user,
          name: user.displayName ?? googleUser.displayName,
          email: user.email ?? googleUser.email,
        );
        _goAfterAuth(profile);
      }
    } on FirebaseAuthException catch (e) {
      showSpotlightToast(
        context,
        e.message ?? 'Google sign-in failed',
        success: false,
      );
    } catch (_) {
      showSpotlightToast(context, 'Google sign-in failed', success: false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handlePhoneSignIn() async {
    final phoneController = TextEditingController();
    final codeController = TextEditingController();
    String? verificationId;
    bool isSending = false;
    bool isVerifying = false;
    bool codeSent = false;
    String dialCode = '+250';
    String fullPhone = '';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final viewInsets = MediaQuery.of(context).viewInsets.bottom;
            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: viewInsets + 20,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          codeSent
                              ? 'Verify your number'
                              : 'Continue with phone',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: isSending || isVerifying
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    codeSent
                        ? 'Enter the code we sent to $fullPhone'
                        : 'We’ll send a one-time code to verify your number.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.grey),
                  ),
                  const SizedBox(height: 16),
                  if (!codeSent) ...[
                    Row(
                      children: [
                        CountryCodePicker(
                          initialSelection: 'RW',
                          favorite: const ['RW', 'KE', 'UG', 'TZ'],
                          showFlag: true,
                          showCountryOnly: false,
                          showOnlyCountryWhenClosed: false,
                          onChanged: (code) {
                            dialCode = code.dialCode ?? '+250';
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              hintText: '7XXXXXXXX',
                              labelText: 'Phone number',
                              prefixIcon: Icon(Icons.phone),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (codeSent) ...[
                    TextField(
                      controller: codeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: '123456',
                        labelText: 'Verification code',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: isVerifying
                            ? null
                            : () {
                                setState(() {
                                  codeSent = false;
                                  isSending = false;
                                  isVerifying = false;
                                  verificationId = null;
                                });
                              },
                        child: const Text('Edit phone number'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isSending || isVerifying
                          ? null
                          : () async {
                              if (!codeSent) {
                                final phone = phoneController.text.trim();
                                if (phone.isEmpty) return;
                                fullPhone = '$dialCode$phone';
                                setState(() {
                                  isSending = true;
                                });
                                await FirebaseAuth.instance.verifyPhoneNumber(
                                  phoneNumber: fullPhone,
                                  verificationCompleted:
                                      (PhoneAuthCredential credential) async {
                                    final userCredential = await FirebaseAuth
                                        .instance
                                        .signInWithCredential(credential);
                                    final user = userCredential.user;
                                    if (user != null) {
                                      final profile = await _ensureUserDocument(
                                        user,
                                        phone: user.phoneNumber ?? fullPhone,
                                      );
                                      _goAfterAuth(profile);
                                      if (mounted) {
                                        if (!context.mounted) return;
                                        Navigator.pop(context);
                                      }
                                    }
                                  },
                                  verificationFailed:
                                      (FirebaseAuthException e) {
                                    showSpotlightToast(
                                      context,
                                      e.message ?? 'Phone verification failed',
                                      success: false,
                                    );
                                    if (context.mounted) {
                                      setState(() {
                                        isSending = false;
                                      });
                                    }
                                  },
                                  codeSent: (String id, int? resendToken) {
                                    verificationId = id;
                                    setState(() {
                                      codeSent = true;
                                      isSending = false;
                                    });
                                  },
                                  codeAutoRetrievalTimeout: (String id) {
                                    verificationId = id;
                                  },
                                );
                              } else {
                                final code = codeController.text.trim();
                                if (code.isEmpty || verificationId == null) {
                                  return;
                                }
                                setState(() {
                                  isVerifying = true;
                                });
                                try {
                                  final credential =
                                      PhoneAuthProvider.credential(
                                    verificationId: verificationId!,
                                    smsCode: code,
                                  );
                                  final userCredential = await FirebaseAuth
                                      .instance
                                      .signInWithCredential(credential);
                                  final user = userCredential.user;
                                  if (user != null) {
                                    final profile = await _ensureUserDocument(
                                      user,
                                      phone: user.phoneNumber ?? fullPhone,
                                    );
                                    _goAfterAuth(profile);
                                    if (mounted) {
                                      Navigator.pop(context);
                                    }
                                  }
                                } on FirebaseAuthException catch (e) {
                                  showSpotlightToast(
                                    context,
                                    e.message ?? 'Invalid verification code',
                                    success: false,
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      isVerifying = false;
                                    });
                                  }
                                }
                              }
                            },
                      child: (isSending || isVerifying)
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(codeSent ? 'Verify' : 'Send code'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldFillColor = isDark
        ? const Color(0xCC1A2230).withOpacity(0.52)
        : Colors.white.withOpacity(0.22);
    final fieldBorderColor = Colors.white.withOpacity(isDark ? 0.18 : 0.14);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: isDark ? 0.5 : 0.42,
                child: Image.asset(
                  'assets/images/chat_bg.gif',
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                color: isDark
                    ? Colors.black.withOpacity(0.34)
                    : Colors.black.withOpacity(0.18),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 80),
                    Center(
                      child: Text(
                        'Create Traffic Account',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          shadows: const [
                            Shadow(
                              color: Colors.black45,
                              blurRadius: 10,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Join SpotLight Traffic operations',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Colors.white70,
                            ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    AppTextField(
                      controller: _usernameController,
                      label: 'Username',
                      hintText: 'lowercase, numbers, . or _',
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[a-z0-9._]')),
                      ],
                      fillColor: fieldFillColor,
                      textColor: Colors.white,
                      hintColor: Colors.white60,
                      borderColor: fieldBorderColor,
                      errorStyle: const TextStyle(
                        color: Colors.redAccent,
                        backgroundColor: Colors.transparent,
                      ),
                      prefixIcon: const Icon(
                        Icons.alternate_email_rounded,
                        color: Colors.white70,
                      ),
                      validator: (value) {
                        final v = (value ?? '').trim().toLowerCase();
                        if (v.isEmpty) {
                          return 'Please choose a username';
                        }
                        final ok = RegExp(r'^[a-z0-9._]{3,20}$').hasMatch(v);
                        if (!ok) {
                          return 'Use 3-20 chars: a-z, 0-9, dot, underscore';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _emailController,
                      label: 'Email',
                      hintText: 'Enter your email',
                      keyboardType: TextInputType.emailAddress,
                      fillColor: fieldFillColor,
                      textColor: Colors.white,
                      hintColor: Colors.white60,
                      borderColor: fieldBorderColor,
                      errorStyle: const TextStyle(
                        color: Colors.redAccent,
                        backgroundColor: Colors.transparent,
                      ),
                      prefixIcon: const Icon(
                        Icons.alternate_email_rounded,
                        color: Colors.white70,
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!value.contains('@')) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _passwordController,
                      label: 'Password',
                      hintText: 'Enter your password',
                      obscureText: true,
                      fillColor: fieldFillColor,
                      textColor: Colors.white,
                      hintColor: Colors.white60,
                      borderColor: fieldBorderColor,
                      errorStyle: const TextStyle(
                        color: Colors.redAccent,
                        backgroundColor: Colors.transparent,
                      ),
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.white70,
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your password';
                        }
                        if (value.length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _confirmPasswordController,
                      label: 'Confirm Password',
                      hintText: 'Confirm your password',
                      obscureText: true,
                      fillColor: fieldFillColor,
                      textColor: Colors.white,
                      hintColor: Colors.white60,
                      borderColor: fieldBorderColor,
                      errorStyle: const TextStyle(
                        color: Colors.redAccent,
                        backgroundColor: Colors.transparent,
                      ),
                      prefixIcon: const Icon(
                        Icons.verified_user_outlined,
                        color: Colors.white70,
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please confirm your password';
                        }
                        if (value != _passwordController.text) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 32),
                    AppButton(
                      text: 'Create Account',
                      onPressed: _handleRegister,
                      isLoading: _isLoading,
                    ),
                    const SizedBox(height: 24),
                    const Row(
                      children: [
                        Expanded(
                          child: Divider(color: AppColors.lightGrey),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Or continue with',
                            style: TextStyle(color: AppColors.grey),
                          ),
                        ),
                        Expanded(
                          child: Divider(color: AppColors.lightGrey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _socialButton(
                          onPressed: _handleGoogleSignIn,
                          assetPath: 'assets/images/google.png',
                          semanticLabel: 'Continue with Google',
                        ),
                        const SizedBox(width: 18),
                        _socialButton(
                          onPressed: _handlePhoneSignIn,
                          assetPath: 'assets/images/phone.png',
                          semanticLabel: 'Continue with phone',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Already have an account? ',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        TextButton(
                          onPressed: () {
                            context.go(AppRoutes.login);
                          },
                          child: Text(
                            'Sign In',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _socialButton({
    required VoidCallback onPressed,
    required String assetPath,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 68,
          height: 68,
          child: Padding(
            padding: EdgeInsets.all(
              assetPath.contains('phone') ? 8 : 6,
            ),
            child: Image.asset(
              assetPath,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
