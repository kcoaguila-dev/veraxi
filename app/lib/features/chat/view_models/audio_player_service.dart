import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';

class AudioPlayerState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final String? playingMessageId;
  final String? playingText;
  final double speed;
  final bool isLoading;

  AudioPlayerState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playingMessageId,
    this.playingText,
    this.speed = 1.0,
    this.isLoading = false,
  });

  AudioPlayerState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    String? playingMessageId,
    String? playingText,
    double? speed,
    bool? isLoading,
  }) {
    return AudioPlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playingMessageId: playingMessageId ?? this.playingMessageId,
      playingText: playingText ?? this.playingText,
      speed: speed ?? this.speed,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AudioPlayerService extends StateNotifier<AudioPlayerState> {
  final AudioPlayer _player = AudioPlayer();
  final TTSRepository _ttsRepository;
  final TTSSettingsStorage _ttsSettingsStorage;

  AudioPlayerService(this._ttsRepository, this._ttsSettingsStorage)
      : super(AudioPlayerState()) {
    _init();
  }

  void _init() {
    _player.positionStream.listen((position) {
      state = state.copyWith(position: position);
    });

    _player.durationStream.listen((duration) {
      if (duration != null) {
        state = state.copyWith(duration: duration);
      }
    });

    _player.playerStateStream.listen((playerState) {
      final isPlaying = playerState.playing;
      final processingState = playerState.processingState;
      if (processingState == ProcessingState.completed) {
        state = state.copyWith(isPlaying: false, position: Duration.zero);
        _player.seek(Duration.zero);
        _player.pause();
      } else {
        state = state.copyWith(isPlaying: isPlaying);
      }
    });
  }

  Future<void> playMessage(String messageId, String text) async {
    if (state.playingMessageId == messageId && !state.isLoading) {
      if (state.isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    state = state.copyWith(
        playingMessageId: messageId,
        playingText: text,
        isLoading: true,
        position: Duration.zero,
        duration: Duration.zero);

    try {
      final voiceId = await _ttsSettingsStorage.getVoiceId() ?? 'default';
      final gptSovitsUrl = await _ttsSettingsStorage.getGptSovitsUrl();

      // Get audio bytes (cached by backend)
      final bytes = await _ttsRepository.getAudioBytes(
        text,
        voiceId,
        gptSovitsUrl: gptSovitsUrl,
        messageId: messageId,
      );

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$messageId.wav');
      await file.writeAsBytes(bytes);

      await _player.setFilePath(file.path);
      await _player.setSpeed(state.speed);
      await _player.play();

      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false);
      print('Error playing audio: $e');
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  void closePlayer() {
    _player.stop();
    state = AudioPlayerState();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

final audioPlayerServiceProvider =
    StateNotifierProvider<AudioPlayerService, AudioPlayerState>((ref) {
  final ttsRepo = ref.watch(ttsRepositoryProvider);
  final ttsSettings = TTSSettingsStorage();
  return AudioPlayerService(ttsRepo, ttsSettings);
});
