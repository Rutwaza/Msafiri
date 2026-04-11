import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/spotlight_toast.dart';
import '../../../features/auth/providers/auth_providers.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _saving = true);
    try {
      final service = ref.read(trafficAuthServiceProvider);
      await service.completeOnboarding(
        displayName: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
      );
      if (!mounted) return;
      context.go(AppRoutes.trafficManagement);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(
        context,
        'Could not complete onboarding: $e',
        success: false,
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Traffic Onboarding')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Set up your traffic profile',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This profile is used only for SpotLight Traffic operations.',
                ),
                const SizedBox(height: 24),
                AppTextField(
                  controller: _nameController,
                  label: 'Full name',
                  hintText: 'Enter your full name',
                  validator: (value) {
                    if ((value ?? '').trim().length < 2) {
                      return 'Enter at least 2 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                AppTextField(
                  controller: _phoneController,
                  label: 'Phone (optional)',
                  hintText: 'e.g. +2507XXXXXXXX',
                  keyboardType: TextInputType.phone,
                ),
                const Spacer(),
                AppButton(
                  text: 'Complete Setup',
                  onPressed: _complete,
                  isLoading: _saving,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
