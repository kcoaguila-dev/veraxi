import 'package:flutter/material.dart';
import 'package:veraxi_app/core/widgets/veraxi_logo.dart';
import 'settings_shared_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'ABOUT VERAXI'),
        Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const VeraxiLogo(size: 48, color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Veraxi Chat',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              Text(
                'Version 1.0.0',
                style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
              ),
              SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SettingsUI.buildLinkButton(context, 'GitHub', Icons.code,
                      'https://github.com/kcoaguila-dev/veraxi'),
                  SizedBox(width: 12),
                  SettingsUI.buildLinkButton(context, 'Website', Icons.language, '/'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
