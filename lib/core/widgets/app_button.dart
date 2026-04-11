import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/colors.dart';
import 'spotlight_loader.dart';

class AppButton extends ConsumerWidget {
  final String text;
  final VoidCallback onPressed;
  final bool isLoading;
  final bool isDisabled;
  final Color? backgroundColor;
  final Color? textColor;
  final Widget? icon;
  final double? width;
  final double? height;
  final bool isOutlined;

  const AppButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.isDisabled = false,
    this.backgroundColor,
    this.textColor,
    this.icon,
    this.width,
    this.height,
    this.isOutlined = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: width ?? double.infinity,
      height: height ?? 56,
      child: isOutlined
          ? OutlinedButton(
              onPressed: isDisabled || isLoading ? null : onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: textColor ?? AppColors.primary,
                side: BorderSide(
                  color: isDisabled
                      ? AppColors.lightGrey
                      : backgroundColor ?? AppColors.primary,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _buildContent(),
            )
          : ElevatedButton(
              onPressed: isDisabled || isLoading ? null : onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDisabled
                    ? AppColors.lightGrey
                    : backgroundColor ?? AppColors.primary,
                foregroundColor: textColor ?? AppColors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _buildContent(),
            ),
    );
  }

  Widget _buildContent() {
    if (isLoading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: SpotlightLoader(size: 22, color: Colors.white),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          icon!,
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: isOutlined
                ? (textColor ?? AppColors.primary)
                : (textColor ?? AppColors.white),
          ),
        ),
      ],
    );
  }
}
