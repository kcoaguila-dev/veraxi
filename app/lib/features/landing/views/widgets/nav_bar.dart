import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class NavBar extends StatelessWidget {
  const NavBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 80,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: AppTheme.surfaceHighlight, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.change_history, color: AppTheme.primary, size: 28),
              const SizedBox(width: 8),
              Text(
                'Veraxi',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          if (MediaQuery.of(context).size.width > 800)
            Row(
              children: [
                _NavLink('Features'),
                const SizedBox(width: 32),
                _NavLink('Docs'),
                const SizedBox(width: 32),
                _NavLink('MCP Protocol'),
                const SizedBox(width: 32),
                _NavLink('GitHub'),
              ],
            ),
          Row(
            children: [
              TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(foregroundColor: AppTheme.textPrimary),
                child: const Text('Sign In'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => context.go('/chat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.textPrimary,
                  foregroundColor: AppTheme.background,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Get Started', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  final String title;
  const _NavLink(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: GoogleFonts.inter(
        color: AppTheme.textSecondary,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
