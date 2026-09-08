import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ModelProviderStyles {
  static Widget getProviderCircle(String provider) {
    String? assetPath;
    final lower = provider.toLowerCase();
    
    if (lower == 'google') {
      assetPath = 'assets/icons/google.svg';
    } else if (lower == 'openai') {
      assetPath = 'assets/icons/openai.svg';
    } else if (lower == 'anthropic') {
      assetPath = 'assets/icons/anthropic.svg';
    } else if (lower == 'deepseek') {
      assetPath = 'assets/icons/deepseek.svg';
    } else if (lower == 'groq') {
      assetPath = 'assets/icons/groq.svg';
    } else if (lower == 'mistral' || lower == 'mixtral') {
      assetPath = 'assets/icons/mistral.svg';
    } else if (lower == 'kimi') {
      assetPath = 'assets/icons/kimi.svg';
    } else if (lower == 'local') {
      assetPath = 'assets/icons/local.svg';
    }

    final colors = {
      'Google': Colors.white,
      'OpenAI': Colors.white,
      'Anthropic': const Color(0xFFd97757),
      'Mistral': const Color(0xFFFF9800),
      'DeepSeek': const Color(0xFF2196F3),
      'groq': const Color(0xFFf55036),
      'HuggingFace': const Color(0xFFFFC107),
      'Hyperbolic': const Color(0xFF673AB7),
      'cohere': const Color(0xFF81C784),
      'Kimi': Colors.white,
      'Local': Colors.white,
    };

    if (assetPath != null) {
      final colorKey = colors.keys.firstWhere(
        (k) => k.toLowerCase() == lower,
        orElse: () => 'OpenAI',
      );
      final iconColor = colors[colorKey] ?? Colors.white;
      
      return SizedBox(
        width: 16,
        height: 16,
        child: Center(
          child: SvgPicture.asset(
            assetPath,
            width: 16,
            height: 16,
            colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
          ),
        ),
      );
    }

    final color = colors[provider];
    if (color == null) return const SizedBox(width: 16);
    
    return Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
