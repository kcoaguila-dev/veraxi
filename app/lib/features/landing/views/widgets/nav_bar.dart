import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/theme.dart';

class NavBar extends StatelessWidget {
  final VoidCallback? onFeaturesTap;
  const NavBar({super.key, this.onFeaturesTap});

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
                  _NavLink(
                    title: 'Features',
                    onTap: onFeaturesTap ?? () {},
                  ),
                  const SizedBox(width: 32),
                  _NavLink(
                    title: 'Docs',
                    onTap: () => context.go('/docs'),
                  ),
                  const SizedBox(width: 32),
                  _NavLink(
                    title: 'MCP Protocol',
                    onTap: () => _launchUrl('https://modelcontextprotocol.io'),
                  ),
                  const SizedBox(width: 32),
                  _NavLink(
                    title: 'GitHub',
                    onTap: () => _launchUrl('https://github.com/kcoaguila-dev/veraxi'),
                  ),
                ],
              ),
            Row(
              children: [
                TextButton(
                  onPressed: () => context.go('/login'),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.textPrimary),
                  child: const Text('Sign In'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () => context.go('/login'),
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

    Future<void> _launchUrl(String url) async {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }

  class _NavLink extends StatefulWidget {
    final String title;
    final VoidCallback onTap;

    const _NavLink({required this.title, required this.onTap});

    @override
    State<_NavLink> createState() => _NavLinkState();
  }

  class _NavLinkState extends State<_NavLink> {
    bool _isHovered = false;

    @override
    Widget build(BuildContext context) {
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _isHovered ? 1.0 : 0.7,
            child: Text(
              widget.title,
              style: GoogleFonts.inter(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }
  }
