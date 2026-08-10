// ignore: avoid_web_libraries_in_flutter
// ignore_for_file: deprecated_member_use
import 'dart:html' as html;
import 'package:sentry_flutter/sentry_flutter.dart';

/// Real web implementation of WebSpeechService using the browser's native
/// SpeechSynthesis API (dart:html). Only compiled on web targets.
///
/// This is the industry-standard free TTS used by LibreChat and Open WebUI —
/// no API key, no backend call, uses the OS's own voice engine.
class WebSpeechService {
  WebSpeechService._();
  static final WebSpeechService instance = WebSpeechService._();

  html.SpeechSynthesis? get _synth {
    try {
      return html.window.speechSynthesis;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      return null;
    }
  }

  /// Whether the browser supports SpeechSynthesis.
  bool get isSupported => _synth != null;

  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;

  /// Speaks the given [text] using the browser's built-in TTS engine.
  ///
  /// Picks the best available English voice: tries Google UK English Female
  /// first, then any Google voice, then en-US, then the OS default.
  void speak(String text) {
    final synth = _synth;
    if (synth == null) return;

    stop();

    final utterance = html.SpeechSynthesisUtterance(text);
    utterance.rate = 1.0;
    utterance.pitch = 1.0;
    utterance.volume = 1.0;

    final voices = synth.getVoices();

    // Priority 1: Google UK English Female (Chrome on most OS)
    html.SpeechSynthesisVoice? selectedVoice =
        _findVoice(voices, 'Google UK English Female');
    // Priority 2: Any Google English voice
    selectedVoice ??= _findVoice(voices, 'Google');
    // Priority 3: Any en-US voice
    selectedVoice ??= voices.cast<html.SpeechSynthesisVoice?>().firstWhere(
          (v) => v?.lang == 'en-US',
          orElse: () => null,
        );

    if (selectedVoice != null) {
      utterance.voice = selectedVoice;
    }

    utterance.onStart.listen((_) => _isSpeaking = true);
    utterance.onEnd.listen((_) => _isSpeaking = false);
    utterance.onError.listen((_) => _isSpeaking = false);

    synth.speak(utterance);
    _isSpeaking = true;
  }

  /// Stops any currently playing speech.
  void stop() {
    _synth?.cancel();
    _isSpeaking = false;
  }

  /// Pauses speech synthesis.
  void pause() => _synth?.pause();

  /// Resumes paused speech synthesis.
  void resume() => _synth?.resume();

  html.SpeechSynthesisVoice? _findVoice(
    List<html.SpeechSynthesisVoice> voices,
    String namePrefix,
  ) {
    return voices.cast<html.SpeechSynthesisVoice?>().firstWhere(
          (v) =>
              v?.name?.toLowerCase().contains(namePrefix.toLowerCase()) ??
              false,
          orElse: () => null,
        );
  }
}
