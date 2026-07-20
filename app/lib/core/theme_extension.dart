import 'package:flutter/material.dart';

class AppThemeExtension extends ThemeExtension<AppThemeExtension> {
  final Color primaryGradientStart;
  final Color primaryGradientEnd;
  final Color surfaceHighlight;

  const AppThemeExtension({
    required this.primaryGradientStart,
    required this.primaryGradientEnd,
    required this.surfaceHighlight,
  });

  @override
  ThemeExtension<AppThemeExtension> copyWith({
    Color? primaryGradientStart,
    Color? primaryGradientEnd,
    Color? surfaceHighlight,
  }) {
    return AppThemeExtension(
      primaryGradientStart: primaryGradientStart ?? this.primaryGradientStart,
      primaryGradientEnd: primaryGradientEnd ?? this.primaryGradientEnd,
      surfaceHighlight: surfaceHighlight ?? this.surfaceHighlight,
    );
  }

  @override
  ThemeExtension<AppThemeExtension> lerp(ThemeExtension<AppThemeExtension>? other, double t) {
    if (other is! AppThemeExtension) {
      return this;
    }
    return AppThemeExtension(
      primaryGradientStart: Color.lerp(primaryGradientStart, other.primaryGradientStart, t)!,
      primaryGradientEnd: Color.lerp(primaryGradientEnd, other.primaryGradientEnd, t)!,
      surfaceHighlight: Color.lerp(surfaceHighlight, other.surfaceHighlight, t)!,
    );
  }
}
