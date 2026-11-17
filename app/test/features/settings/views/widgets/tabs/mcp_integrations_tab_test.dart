import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/data/integrations_repository.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/connected_apps_tab.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/mcp_integrations_tab.dart';

class MockIntegrationsRepository extends Mock
    implements IntegrationsRepository {}

void main() {
  late MockIntegrationsRepository mockRepository;

  setUp(() {
    mockRepository = MockIntegrationsRepository();
    when(() => mockRepository.getIntegrations()).thenAnswer((_) async => [
          const IntegrationModel(
            id: '1',
            kind: 'mcp',
            provider: 'custom_mcp',
            slug: 'docs-mcp',
            displayName: 'Docs MCP',
            config: {
              'url': 'https://mcp.example.com/mcp',
              'tool_names': ['a', 'b'],
            },
            hasAuth: true,
            isEnabled: true,
            status: 'connected',
          ),
          const IntegrationModel(
            id: '2',
            kind: 'oauth',
            provider: 'github',
            slug: 'github',
            displayName: 'GitHub',
            config: {},
            hasAuth: true,
            isEnabled: true,
            status: 'connected',
          ),
        ]);
    when(() => mockRepository.getOAuthProviders()).thenAnswer((_) async => [
          const OAuthProviderModel(
            provider: 'github',
            displayName: 'GitHub',
            enabled: true,
            configured: true,
          ),
          const OAuthProviderModel(
            provider: 'notion',
            displayName: 'Notion',
            enabled: false,
            configured: false,
          ),
        ]);
  });

  testWidgets('McpIntegrationsTab renders only MCP/OpenAPI integrations',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          integrationsRepositoryProvider.overrideWithValue(mockRepository),
        ],
        child: MaterialApp(
          theme: ThemeData().copyWith(
            extensions: [
              AppThemeExtension(
                primaryGradientStart: Colors.blue,
                primaryGradientEnd: Colors.blueAccent,
                surfaceHighlight: Colors.grey,
                sidebarBackground: Colors.black,
                cardBackground: Colors.black54,
                dialogBackground: Colors.black87,
                borderColor: Colors.white24,
                borderColorStrong: Colors.white54,
                textTertiary: Colors.grey,
                iconColor: Colors.white,
              ),
            ],
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: McpIntegrationsTab()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Only MCP/OpenAPI integrations appear here; OAuth apps live in ConnectedAppsTab.
    expect(find.text('Docs MCP'), findsOneWidget);
    expect(find.text('Connected · 2 tools'), findsOneWidget);
    expect(find.text('Test Connection'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);

    expect(find.text('GitHub'), findsNothing);
    expect(find.text('Sync Repos'), findsNothing);

    // Custom integration actions.
    expect(find.text('Add MCP Server'), findsOneWidget);
    expect(find.text('Import OpenAPI Spec'), findsOneWidget);
  });

  testWidgets(
      'ConnectedAppsTab renders connected OAuth apps and available catalog',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          integrationsRepositoryProvider.overrideWithValue(mockRepository),
        ],
        child: MaterialApp(
          theme: ThemeData().copyWith(
            extensions: [
              AppThemeExtension(
                primaryGradientStart: Colors.blue,
                primaryGradientEnd: Colors.blueAccent,
                surfaceHighlight: Colors.grey,
                sidebarBackground: Colors.black,
                cardBackground: Colors.black54,
                dialogBackground: Colors.black87,
                borderColor: Colors.white24,
                borderColorStrong: Colors.white54,
                textTertiary: Colors.grey,
                iconColor: Colors.white,
              ),
            ],
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: ConnectedAppsTab()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Connected section shows GitHub with Disconnect + Sync Repos, not Docs MCP.
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Connected · 6 tools'), findsOneWidget);
    expect(find.text('Sync Repos'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Docs MCP'), findsNothing);

    // Available Apps shows only unconnected providers (Notion).
    expect(find.text('Available Apps'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('Not configured on the server'), findsOneWidget);
  });
}
