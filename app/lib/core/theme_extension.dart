import 'package:flutter/material.dart';



class AppThemeExtension extends ThemeExtension<AppThemeExtension> {
  final Color primaryGradientStart;
  final Color primaryGradientEnd;
  final Color surfaceHighlight;
  final Color sidebarBackground;
  final Color cardBackground;
  final Color dialogBackground;
  final Color borderColor;
  final Color borderColorStrong;
  final Color textTertiary;
  final Color iconColor;

  const AppThemeExtension({
    required this.primaryGradientStart,
    required this.primaryGradientEnd,
    required this.surfaceHighlight,
    required this.sidebarBackground,
    required this.cardBackground,
    required this.dialogBackground,
    required this.borderColor,
    required this.borderColorStrong,
    required this.textTertiary,
    required this.iconColor,
  });

  @override
  ThemeExtension<AppThemeExtension> copyWith({
    Color? primaryGradientStart,
    Color? primaryGradientEnd,
    Color? surfaceHighlight,
    Color? sidebarBackground,
    Color? cardBackground,
    Color? dialogBackground,
    Color? borderColor,
    Color? borderColorStrong,
    Color? textTertiary,
    Color? iconColor,
  }) {
    return AppThemeExtension(
      primaryGradientStart: primaryGradientStart ?? this.primaryGradientStart,
      primaryGradientEnd: primaryGradientEnd ?? this.primaryGradientEnd,
      surfaceHighlight: surfaceHighlight ?? this.surfaceHighlight,
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      cardBackground: cardBackground ?? this.cardBackground,
      dialogBackground: dialogBackground ?? this.dialogBackground,
      borderColor: borderColor ?? this.borderColor,
      borderColorStrong: borderColorStrong ?? this.borderColorStrong,
      textTertiary: textTertiary ?? this.textTertiary,
      iconColor: iconColor ?? this.iconColor,
    );
  }

  @override
  ThemeExtension<AppThemeExtension> lerp(
      ThemeExtension<AppThemeExtension>? other, double t) {
    if (other is! AppThemeExtension) {
      return this;
    }
    return AppThemeExtension(
      primaryGradientStart:
          Color.lerp(primaryGradientStart, other.primaryGradientStart, t)!,
      primaryGradientEnd:
          Color.lerp(primaryGradientEnd, other.primaryGradientEnd, t)!,
      surfaceHighlight:
          Color.lerp(surfaceHighlight, other.surfaceHighlight, t)!,
      sidebarBackground: Color.lerp(sidebarBackground, other.sidebarBackground, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      dialogBackground: Color.lerp(dialogBackground, other.dialogBackground, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      borderColorStrong: Color.lerp(borderColorStrong, other.borderColorStrong, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      iconColor: Color.lerp(iconColor, other.iconColor, t)!,
    );
  }
}
