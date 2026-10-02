import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/widgets/model_selector_menu.dart';
import 'package:veraxi_app/core/theme_extension.dart';

void main() {
  Widget createTestWidget() {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData().copyWith(
          extensions: <ThemeExtension<dynamic>>[
            const AppThemeExtension(
              primaryGradientStart: Color(0xFF000000),
              primaryGradientEnd: Color(0xFF000000),
              sidebarBackground: Color(0xFF1E1E1E),
              cardBackground: Color(0xFF2D2D2D),
              dialogBackground: Color(0xFF2D2D2D),
              surfaceHighlight: Color(0xFF333333),
              textTertiary: Color(0xFF808080),
              iconColor: Color(0xFFCCCCCC),
              borderColor: Color(0xFF404040),
              borderColorStrong: Color(0xFF404040),
            ),
          ],
        ),
        home: Scaffold(
          body: Center(
            child: HoverableProviderRow(
              provider: 'local',
              isHovered: false,
              onEnter: (layerLink) {},
              onTap: (layerLink) {},
              onSettingsTap: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('HoverableProviderRow displays settings gear icon for provider without needing hover', (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());

    // We should immediately see the settings icon without having to hover.
    final settingsIcons = find.byIcon(Icons.settings_outlined);
    expect(settingsIcons, findsOneWidget);
  });
}
