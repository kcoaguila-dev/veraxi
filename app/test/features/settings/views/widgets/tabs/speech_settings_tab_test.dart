import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/speech_settings_tab.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/data/voices_repository.dart';
import 'package:veraxi_app/features/settings/view_models/saved_voices_view_model.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class MockTTSRepository extends Mock implements TTSRepository {}
class MockVoicesRepository extends Mock implements VoicesRepository {}

void main() {
  late MockTTSRepository mockRepository;
  late MockVoicesRepository mockVoicesRepository;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    mockRepository = MockTTSRepository();
    when(() =>
            mockRepository.getVoices(gptSovitsUrl: any(named: 'gptSovitsUrl')))
        .thenAnswer((_) async => [
              {'id': 'default_system', 'name': 'Default (System)'}
            ]);

    mockVoicesRepository = MockVoicesRepository();
    when(() => mockVoicesRepository.getSavedVoices()).thenAnswer((_) async => []);
  });

  testWidgets('SpeechSettingsTab shows Fish Audio in Engine dropdown',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ttsRepositoryProvider.overrideWithValue(mockRepository),
          voicesRepositoryProvider.overrideWithValue(mockVoicesRepository),
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
            body: SpeechSettingsTab(),
          ),
        ),
      ),
    );

    // Let the provider initialize
    await tester.pumpAndSettle();

    // Verify 'TEXT TO SPEECH' section header is present
    expect(find.text('TEXT TO SPEECH'), findsOneWidget);

    // Verify 'Engine' row is present
    expect(find.text('Engine'), findsOneWidget);

    // Tap the Engine dropdown to open the menu
    // The dropdown shows the currently selected engine, which defaults to 'Browser'
    final dropdownFinder = find.text('Browser').first;
    await tester.tap(dropdownFinder);
    await tester.pumpAndSettle();

    // Verify that the dropdown menu contains 'Fish Audio'
    expect(find.text('Browser').last, findsOneWidget);
    expect(find.text('GPT-SoVITS'), findsOneWidget);
    expect(find.text('Fish Audio'), findsOneWidget);

    // Tap 'Fish Audio' to select it
    await tester.tap(find.text('Fish Audio'));
    await tester.pumpAndSettle();

    // Verify that Reference ID input appears
    expect(find.text('Reference ID'), findsOneWidget);

    // Verify that Tier dropdown appears
    expect(find.text('Tier'), findsOneWidget);
    expect(find.text('Pro (s2.1-pro)'), findsOneWidget);
  });
}
