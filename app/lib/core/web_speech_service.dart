/// Platform-aware entry point for WebSpeechService.
///
/// Uses conditional imports to select the correct implementation:
/// - On web: web_speech_service_web.dart (uses dart:html SpeechSynthesis)
/// - On VM / tests: web_speech_service_stub.dart (no-op, avoids dart:html errors)
///
/// This is the standard Flutter pattern for platform-specific code
/// (the same approach used by url_launcher, flutter_secure_storage, etc.)
export 'web_speech_service_stub.dart'
    if (dart.library.html) 'web_speech_service_web.dart';
