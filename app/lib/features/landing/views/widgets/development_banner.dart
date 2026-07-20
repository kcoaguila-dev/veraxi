import 'package:flutter/material.dart';

class DevelopmentBanner extends StatelessWidget {
  const DevelopmentBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: theme.colorScheme.primary, width: 1)),
      ),
      child: Center(
        child: Text(
          'DEVELOPMENT MODE: Sovereign Local Instance',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
