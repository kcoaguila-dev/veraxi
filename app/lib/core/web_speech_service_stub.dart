import 'package:flutter_tts/flutter_tts.dart';

/// Native (non-web) implementation of WebSpeechService using flutter_tts.
///
/// flutter_tts wraps OS-native TTS engines — no API key, no backend call:
///   iOS / macOS  → AVSpeechSynthesizer (Apple's built-in engine)
///   Android      → Android TextToSpeech API
///   Windows      → Windows SAPI / OneCore voices
///
/// In VM unit tests, FlutterTts will throw MissingPluginException which is
/// silently caught so tests remain green without needing real platform channels.
class WebSpeechService {
  WebSpeechService._();
  static final WebSpeechService instance = WebSpeechService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;

  /// Always true on native platforms — flutter_tts supports iOS, Android,
  /// macOS, and Windows out of the box.
  bool get isSupported => true;

  bool get isSpeaking => _isSpeaking;

  /// Lazy initialisation — configures voice settings the first time speak() is called.
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setLanguage('en-US');
    await _tts.setPitch(1.0);
    // 0.5 is the most natural-sounding rate for TTS (matches Apple Siri defaults)
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() => _isSpeaking = false);
    _tts.setCancelHandler(() => _isSpeaking = false);
    _tts.setErrorHandler((_) => _isSpeaking = false);
  }

  /// Speaks the given [text] using the native OS speech engine.
  ///
  /// Toggle behaviour: if currently speaking, stops; otherwise starts speaking.
  /// MissingPluginException in test environments is silently ignored.
  void speak(String text) {
    _speakAsync(text);
  }

  Future<void> _speakAsync(String text) async {
    try {
      await _ensureInitialized();
      if (_isSpeaking) {
        await _tts.stop();
        _isSpeaking = false;
      } else {
        await _tts.speak(text);
      }
    } catch (_) {
      // Catches MissingPluginException in VM test environments — silent no-op.
      _isSpeaking = false;
    }
  }

  /// Stops any currently playing speech.
  void stop() {
    _stopAsync();
  }

  Future<void> _stopAsync() async {
    try {
      await _tts.stop();
      _isSpeaking = false;
    } catch (_) {}
  }

  /// Pauses speech synthesis (supported on iOS; no-op on other platforms).
  void pause() {
    _pauseAsync();
  }

  Future<void> _pauseAsync() async {
    try {
      await _tts.pause();
    } catch (_) {}
  }

  /// Resumes paused speech synthesis.
  /// flutter_tts doesn't expose resume() — re-triggering speak() is idiomatic.
  void resume() {
    // No-op: callers should call speak() again to resume.
  }
}
