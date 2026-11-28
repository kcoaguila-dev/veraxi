import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';

void main() {
  test('workspaceModeProvider persists and restores WorkspaceMode.code',
      () async {
    SharedPreferences.setMockInitialValues({});

    final first = ProviderContainer();
    expect(first.read(workspaceModeProvider), WorkspaceMode.chat);
    first.read(workspaceModeProvider.notifier).state = WorkspaceMode.code;
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    final second = ProviderContainer();
    expect(second.read(workspaceModeProvider), WorkspaceMode.chat);
    await Future<void>.delayed(Duration.zero);
    expect(second.read(workspaceModeProvider), WorkspaceMode.code);
    second.dispose();
  });

  test(
      'codeAutonomyModeProvider persists and restores selected permission tier',
      () async {
    SharedPreferences.setMockInitialValues({});

    final first = ProviderContainer();
    expect(first.read(codeAutonomyModeProvider), 'auto_read_test');
    first.read(codeAutonomyModeProvider.notifier).state = 'autonomous';
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    final second = ProviderContainer();
    expect(second.read(codeAutonomyModeProvider), 'auto_read_test');
    await Future<void>.delayed(Duration.zero);
    expect(second.read(codeAutonomyModeProvider), 'autonomous');
    second.dispose();
  });
}
