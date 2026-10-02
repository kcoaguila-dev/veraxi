import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';

class GlobalAudioPlayer extends ConsumerStatefulWidget {
  final String messageId;
  const GlobalAudioPlayer({Key? key, required this.messageId})
      : super(key: key);

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

    final position =
        _dragValue ?? audioState.position.inMilliseconds.toDouble();
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 460;
          if (isMobile) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _buildPlayButton(audioState, audioService),
                    _buildSkipButton(
                        audioState,
                        audioService,
                        const Duration(seconds: -10),
                        'Rewind 10s',
                        Icons.replay_10),
                    _buildSkipButton(
                        audioState,
                        audioService,
                        const Duration(seconds: 10),
                        'Forward 10s',
                        Icons.forward_10),
                    const Spacer(),
                    _buildSpeedButton(audioState, audioService),
                    _buildCloseButton(audioService),
                  ],
                ),
                Row(
                  children: [
                    Text(
                      _formatDuration(
                          Duration(milliseconds: displayPos.toInt())),
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    Expanded(
                        child: _buildSlider(audioService, displayPos, maxPos)),
                    Text(
                      _formatDuration(audioState.duration),
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ],
            );
          }

          return Row(
            children: [
              _buildPlayButton(audioState, audioService),
              _buildSkipButton(audioState, audioService,
                  const Duration(seconds: -10), 'Rewind 10s', Icons.replay_10),
              _buildSkipButton(audioState, audioService,
                  const Duration(seconds: 10), 'Forward 10s', Icons.forward_10),
              const SizedBox(width: 8),
              Text(
                _formatDuration(Duration(milliseconds: displayPos.toInt())),
                style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              Expanded(child: _buildSlider(audioService, displayPos, maxPos)),
              Text(
                _formatDuration(audioState.duration),
                style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 8),
              _buildSpeedButton(audioState, audioService),
              _buildCloseButton(audioService),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlayButton(
      AudioPlayerState audioState, AudioPlayerService audioService) {
    return IconButton(
      icon: audioState.isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(audioState.isPlaying ? LucideIcons.pause : LucideIcons.play,
              size: 20),
      onPressed: audioState.isLoading
          ? null
          : () => audioState.isPlaying
              ? audioService.pause()
              : audioService.playMessage(
                  audioState.playingMessageId!, audioState.playingText!),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  Widget _buildSkipButton(
      AudioPlayerState audioState,
      AudioPlayerService audioService,
      Duration offset,
      String tooltip,
      IconData icon) {
    return IconButton(
      icon: Icon(icon, size: 20),
      onPressed: () {
        final newPos = audioState.position + offset;
        audioService.seek(newPos < Duration.zero
            ? Duration.zero
            : newPos > audioState.duration
                ? audioState.duration
                : newPos);
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: tooltip,
    );
  }

  Widget _buildSlider(
      AudioPlayerService audioService, double displayPos, double maxPos) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: Slider(
        value: displayPos,
        min: 0,
        max: maxPos,
        onChanged: (value) => setState(() => _dragValue = value),
        onChangeEnd: (value) {
          audioService.seek(Duration(milliseconds: value.toInt()));
          setState(() => _dragValue = null);
        },
      ),
    );
  }

  Widget _buildSpeedButton(
      AudioPlayerState audioState, AudioPlayerService audioService) {
    return TextButton(
      onPressed: () {
        final nextSpeed = audioState.speed >= 2.0
            ? 1.0
            : audioState.speed >= 1.5
                ? 2.0
                : audioState.speed >= 1.25
                    ? 1.5
                    : 1.25;
        audioService.setSpeed(nextSpeed);
      },
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 36),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      child: Text('${audioState.speed}x',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildCloseButton(AudioPlayerService audioService) {
    return IconButton(
      icon: const Icon(LucideIcons.x, size: 18),
      onPressed: audioService.closePlayer,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: 'Close player',
    );
  }
}
