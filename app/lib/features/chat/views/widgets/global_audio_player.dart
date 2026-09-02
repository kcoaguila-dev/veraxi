import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';

class GlobalAudioPlayer extends ConsumerWidget {
  const GlobalAudioPlayer({Key? key}) : super(key: key);

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioPlayerServiceProvider);
    final audioService = ref.read(audioPlayerServiceProvider.notifier);
    final theme = Theme.of(context);

    if (audioState.playingMessageId == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  audioState.playingText ?? 'Playing audio...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.x, size: 20),
                onPressed: () => audioService.closePlayer(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                icon: audioState.isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        audioState.isPlaying
                            ? LucideIcons.pause
                            : LucideIcons.play,
                      ),
                onPressed: audioState.isLoading
                    ? null
                    : () {
                        if (audioState.isPlaying) {
                          audioService.pause();
                        } else {
                          audioService.playMessage(
                            audioState.playingMessageId!,
                            audioState.playingText!,
                          );
                        }
                      },
              ),
              Text(
                _formatDuration(audioState.position),
                style: theme.textTheme.bodySmall,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4.0,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                  ),
                  child: Slider(
                    value: audioState.position.inMilliseconds.toDouble(),
                    min: 0.0,
                    max: audioState.duration.inMilliseconds.toDouble() > 0 
                      ? audioState.duration.inMilliseconds.toDouble() 
                      : 1.0,
                    onChanged: (value) {
                      audioService.seek(Duration(milliseconds: value.toInt()));
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(audioState.duration),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () {
                  final currentSpeed = audioState.speed;
                  final nextSpeed = currentSpeed >= 2.0
                      ? 1.0
                      : currentSpeed >= 1.5
                          ? 2.0
                          : currentSpeed >= 1.25
                              ? 1.5
                              : 1.25;
                  audioService.setSpeed(nextSpeed);
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '${audioState.speed}x',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
