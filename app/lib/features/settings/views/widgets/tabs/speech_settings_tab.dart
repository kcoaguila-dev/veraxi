import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/settings/view_models/tts_settings_view_model.dart';
import '../manage_voices_dialog.dart';
import 'settings_shared_ui.dart';

class SpeechSettingsTab extends ConsumerWidget {
  const SpeechSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ttsState = ref.watch(ttsSettingsViewModelProvider);
    final isBrowser = ttsState.selectedEngine == 'Browser';

    String voiceDisplay;
    List<String> voiceOptions;

    if (isBrowser) {
      voiceDisplay = 'Default (System)';
      voiceOptions = ['Default (System)'];
    } else {
      if (ttsState.isLoading) {
        voiceDisplay = 'Loading...';
        voiceOptions = ['Loading...'];
      } else if (ttsState.error != null ||
          ttsState.voices.isEmpty ||
          (ttsState.voices.length == 1 &&
              ttsState.voices.first['id'] == 'default_system')) {
        voiceDisplay = 'No voices available';
        voiceOptions = ['No voices available'];
      } else {
        final customVoices =
            ttsState.voices.where((v) => v['id'] != 'default_system').toList();
        if (customVoices.isEmpty) {
          voiceDisplay = 'No voices available';
          voiceOptions = ['No voices available'];
        } else {
          final selected = customVoices.firstWhere(
              (v) => v['id'] == ttsState.selectedVoiceId,
              orElse: () => customVoices.first);
          voiceDisplay = selected['name'] ?? 'Unknown';
          voiceOptions = customVoices.map((v) => v['name'].toString()).toList();
        }
      }
    }

    final urlController = TextEditingController(text: ttsState.gptSovitsUrl);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'TEXT TO SPEECH'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildRealDropdownRow(
            context,
            'Engine',
            ttsState.selectedEngine,
            ['Browser', 'GPT-SoVITS'],
            (value) {
              ref.read(ttsSettingsViewModelProvider.notifier).setEngine(value);
            },
          ),
          if (!isBrowser)
            SettingsUI.buildTextFieldRow(context, 
              'API Base URL',
              urlController,
              onSubmitted: (value) {
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setGptSovitsUrl(value);
              },
            ),
          SettingsUI.buildRealDropdownRow(
            context,
            'Voice',
            voiceDisplay,
            voiceOptions,
            (value) {
              if (isBrowser ||
                  value == 'Loading...' ||
                  value == 'No voices available') return;
              final voiceId =
                  ttsState.voices.firstWhere((v) => v['name'] == value)['id']!;
              ref.read(ttsSettingsViewModelProvider.notifier).setVoice(voiceId);
            },
          ),
          SettingsUI.buildDropdownRow(context, 'Playback speed', '1.0x'),
          if (ttsState.selectedEngine == 'GPT-SoVITS')
            SettingsUI.buildActionRow(context, 
              'Manage Voices',
              'Add or configure GPT-SoVITS personas',
              'Manage',
              onTap: () {
                showDialog(
                  context: context,
                  builder: (context) => const ManageVoicesDialog(),
                );
              },
            ),
        ]),
        const SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'SPEECH TO TEXT'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildDropdownRow(context, 'Language', 'Auto-detect'),
        ]),
      ],
    );
  }
}
