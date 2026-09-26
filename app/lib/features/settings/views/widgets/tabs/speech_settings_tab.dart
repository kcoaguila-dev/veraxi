import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/settings/view_models/tts_settings_view_model.dart';
import 'package:veraxi_app/features/settings/view_models/saved_voices_view_model.dart';
import '../manage_voices_dialog.dart';
import 'settings_shared_ui.dart';

class SpeechSettingsTab extends ConsumerWidget {
  const SpeechSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ttsState = ref.watch(ttsSettingsViewModelProvider);
    final isBrowser = ttsState.selectedEngine == 'Browser';
    final isFishAudio = ttsState.selectedEngine == 'Fish Audio';

    String voiceDisplay;
    List<String> voiceOptions;

    if (isBrowser) {
      voiceDisplay = 'Default (System)';
      voiceOptions = ['Default (System)'];
    } else if (isFishAudio) {
      voiceDisplay = 'Not applicable';
      voiceOptions = ['Not applicable'];
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
            ['Browser', 'GPT-SoVITS', 'Fish Audio'],
            (value) {
              ref.read(ttsSettingsViewModelProvider.notifier).setEngine(value);
            },
          ),
          if (ttsState.selectedEngine == 'GPT-SoVITS')
            SettingsUI.buildTextFieldRow(
              context,
              'API Base URL',
              urlController,
              onSubmitted: (value) {
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setGptSovitsUrl(value);
              },
            ),
          if (isFishAudio) ...[
            SettingsUI.buildToggleRow(
              context,
              'Self-Hosted Fish Speech',
              ttsState.isSelfHostedFish,
              onChanged: (value) {
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setIsSelfHostedFish(value);
              },
            ),
            if (ttsState.isSelfHostedFish)
              SettingsUI.buildTextFieldRow(
                context,
                'Local Server URL',
                TextEditingController(text: ttsState.fishSpeechUrl),
                onSubmitted: (value) {
                  ref
                      .read(ttsSettingsViewModelProvider.notifier)
                      .setFishSpeechUrl(value);
                },
              ),
            SettingsUI.buildTextFieldRow(
              context,
              'Model ID',
              TextEditingController(text: ttsState.fishAudioReferenceId),
              onSubmitted: (value) {
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setFishAudioReferenceId(value);
              },
            ),
            Consumer(builder: (context, ref, _) {
              final savedVoices = ref.watch(savedVoicesProvider);
              return savedVoices.when(
                data: (voices) {
                  return Column(
                    children: [
                      if (voices.isNotEmpty)
                        SettingsUI.buildRealDropdownRow(
                          context,
                          'Saved Voices',
                          voices.any((v) =>
                                  v.referenceId ==
                                  ttsState.fishAudioReferenceId)
                              ? voices
                                  .firstWhere((v) =>
                                      v.referenceId ==
                                      ttsState.fishAudioReferenceId)
                                  .name
                              : 'Custom...',
                          ['Custom...', ...voices.map((v) => v.name)],
                          (value) {
                            if (value == 'Custom...') return;
                            final selected =
                                voices.firstWhere((v) => v.name == value);
                            ref
                                .read(ttsSettingsViewModelProvider.notifier)
                                .setFishAudioReferenceId(selected.referenceId);
                          },
                        ),
                      SettingsUI.buildActionRow(
                        context,
                        'Save Current Voice',
                        'Save this reference ID to your account',
                        'Save',
                        onTap: () async {
                          if (ttsState.fishAudioReferenceId.isEmpty) return;
                          String? name = await showDialog<String>(
                            context: context,
                            builder: (context) {
                              final nameController = TextEditingController();
                              return AlertDialog(
                                title: const Text('Save Voice',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: const Color(0xFF1E1E1E),
                                content: TextField(
                                  controller: nameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: const InputDecoration(
                                    hintText: 'Voice Name',
                                    hintStyle: TextStyle(color: Colors.white54),
                                    enabledBorder: UnderlineInputBorder(
                                        borderSide:
                                            BorderSide(color: Colors.white24)),
                                    focusedBorder: UnderlineInputBorder(
                                        borderSide: BorderSide(
                                            color: Colors.blueAccent)),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Cancel',
                                        style:
                                            TextStyle(color: Colors.white70)),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(
                                        context, nameController.text),
                                    child: const Text('Save',
                                        style: TextStyle(
                                            color: Colors.blueAccent)),
                                  ),
                                ],
                              );
                            },
                          );
                          if (name != null && name.isNotEmpty) {
                            ref
                                .read(savedVoicesProvider.notifier)
                                .saveVoice(name, ttsState.fishAudioReferenceId);
                          }
                        },
                      ),
                    ],
                  );
                },
                loading: () => const SizedBox(),
                error: (e, _) => const SizedBox(),
              );
            }),
            SettingsUI.buildRealDropdownRow(
              context,
              'Tier',
              ttsState.fishAudioModel == 's2.1-pro-free'
                  ? 'Free (s2.1-pro-free)'
                  : 'Pro (s2.1-pro)',
              ['Pro (s2.1-pro)', 'Free (s2.1-pro-free)'],
              (value) {
                final model = value == 'Free (s2.1-pro-free)'
                    ? 's2.1-pro-free'
                    : 's2.1-pro';
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setFishAudioModel(model);
              },
            ),
          ],
          if (!isFishAudio)
            SettingsUI.buildRealDropdownRow(
              context,
              'Voice',
              voiceDisplay,
              voiceOptions,
              (value) {
                if (isBrowser ||
                    value == 'Loading...' ||
                    value == 'No voices available') return;
                final voiceId = ttsState.voices
                    .firstWhere((v) => v['name'] == value)['id']!;
                ref
                    .read(ttsSettingsViewModelProvider.notifier)
                    .setVoice(voiceId);
              },
            ),
          SettingsUI.buildDropdownRow(context, 'Playback speed', '1.0x'),
          if (ttsState.selectedEngine == 'GPT-SoVITS')
            SettingsUI.buildActionRow(
              context,
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
