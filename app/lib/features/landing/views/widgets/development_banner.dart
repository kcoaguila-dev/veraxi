import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class DevelopmentBanner extends StatelessWidget {
  const DevelopmentBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.15),
        border: const Border(bottom: BorderSide(color: AppTheme.primary, width: 1)),
      ),
      child: Center(
        child: Text(
          'Veraxi is still in development. Join the waitlist for early access.',
          style: GoogleFonts.inter(
            color: AppTheme.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
