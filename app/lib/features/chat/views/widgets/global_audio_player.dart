import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';

class GlobalAudioPlayer extends ConsumerStatefulWidget {
  final String messageId;
  const GlobalAudioPlayer({Key? key, required this.messageId}) : super(key: key);

  @override
  ConsumerState<GlobalAudioPlayer> createState() => _GlobalAudioPlayerState();
}

class _GlobalAudioPlayerState extends ConsumerState<GlobalAudioPlayer> {
  double? _dragValue;

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final audioState = ref.watch(audioPlayerServiceProvider);
    final audioService = ref.read(audioPlayerServiceProvider.notifier);
    final theme = Theme.of(context);

    if (audioState.playingMessageId != widget.messageId) {
      return const SizedBox.shrink();
    }

    final position = _dragValue ?? audioState.position.inMilliseconds.toDouble();
    final duration = audioState.duration.inMilliseconds.toDouble();
    final maxPos = duration > 0 ? duration : 1.0;
    final displayPos = position.clamp(0.0, maxPos);

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
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
                    size: 20,
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
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: const Icon(Icons.replay_10, size: 20),
            onPressed: () {
              final newPos = audioState.position - const Duration(seconds: 10);
              audioService.seek(newPos < Duration.zero ? Duration.zero : newPos);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Rewind 10s',
          ),
          IconButton(
            icon: const Icon(Icons.forward_10, size: 20),
            onPressed: () {
              final newPos = audioState.position + const Duration(seconds: 10);
              audioService.seek(newPos > audioState.duration ? audioState.duration : newPos);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Forward 10s',
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(Duration(milliseconds: displayPos.toInt())),
            style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
              ),
              child: Slider(
                value: displayPos,
                min: 0.0,
                max: maxPos,
                onChanged: (value) {
                  setState(() {
                    _dragValue = value;
                  });
                },
                onChangeEnd: (value) {
                  audioService.seek(Duration(milliseconds: value.toInt()));
                  setState(() {
                    _dragValue = null;
                  });
                },
              ),
            ),
          ),
          Text(
            _formatDuration(audioState.duration),
            style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
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
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 36),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: Text(
              '${audioState.speed}x',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: () => audioService.closePlayer(),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Close player',
          ),
        ],
      ),
    );
  }
}
