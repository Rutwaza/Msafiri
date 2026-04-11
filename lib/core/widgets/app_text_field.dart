import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/colors.dart';

class AppTextField extends StatelessWidget {
  final String label;
  final String? hintText;
  final TextEditingController? controller;
  final TextInputType keyboardType;
  final bool obscureText;
  final bool readOnly;
  final Widget? suffixIcon;
  final Widget? prefixIcon;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final void Function()? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final bool enabled;
  final TextCapitalization textCapitalization;
  final FocusNode? focusNode;
  final Color? fillColor;
  final Color? hintColor;
  final Color? textColor;
  final Color? borderColor;
  final TextStyle? errorStyle;

  const AppTextField({
    super.key,
    required this.label,
    this.hintText,
    this.controller,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
    this.readOnly = false,
    this.suffixIcon,
    this.prefixIcon,
    this.validator,
    this.onChanged,
    this.onTap,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.enabled = true,
    this.textCapitalization = TextCapitalization.none,
    this.focusNode,
    this.fillColor,
    this.hintColor,
    this.textColor,
    this.borderColor,
    this.errorStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final labelStyle = theme.textTheme.labelLarge;
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: hintColor ?? (isDark ? Colors.white54 : AppColors.grey),
    );
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: textColor ??
          (enabled ? (isDark ? Colors.white : AppColors.black) : AppColors.grey),
    );
    final resolvedFillColor = fillColor ??
        (enabled
            ? theme.cardColor
            : (isDark ? const Color(0xFF1C212B) : AppColors.lightGrey));
    final resolvedBorderColor =
        borderColor ?? (isDark ? Colors.white24 : AppColors.lightGrey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: labelStyle,
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscureText,
          readOnly: readOnly,
          enabled: enabled,
          focusNode: focusNode,
          textCapitalization: textCapitalization,
          maxLines: maxLines,
          minLines: minLines,
          maxLength: maxLength,
          inputFormatters: inputFormatters,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: hintStyle,
            filled: true,
            fillColor: resolvedFillColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: resolvedBorderColor,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: resolvedBorderColor,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.primary, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.error),
            ),
            errorStyle: errorStyle,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            prefixIcon: prefixIcon,
            suffixIcon: suffixIcon,
            errorMaxLines: 2,
          ),
          style: textStyle,
          validator: validator,
          onChanged: onChanged,
          onTap: onTap,
        ),
      ],
    );
  }
}
