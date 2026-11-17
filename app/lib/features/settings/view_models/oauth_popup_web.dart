import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'oauth_popup_types.dart';

/// Opens [url] in a centered OAuth popup and awaits the callback postMessage.
///
/// Returns `null` if the browser blocked the popup so the caller can fall back
/// to a same-tab redirect.
Future<OAuthPopupResult?> launchOAuthPopup(
  String url,
  String provider,
) async {
  const width = 600;
  const height = 720;
  final left = web.window.screenX + ((web.window.outerWidth - width) ~/ 2);
  final top = web.window.screenY + ((web.window.outerHeight - height) ~/ 2);
  final features = 'popup=yes,width=$width,height=$height,left=$left,top=$top';

  final popup = web.window.open(url, 'veraxi_oauth', features);
  if (popup == null) {
    return null;
  }

  final completer = Completer<OAuthPopupResult>();
  late final StreamSubscription<web.MessageEvent> sub;
  late final Timer closedPoll;

  void finish(OAuthPopupResult result) {
    if (completer.isCompleted) return;
    sub.cancel();
    closedPoll.cancel();
    completer.complete(result);
  }

  sub = web.window.onMessage.listen((event) {
    final parsed = _parseOAuthMessage(event.data, provider);
    if (parsed != null) {
      finish(parsed);
    }
  });

  closedPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (popup.closed) {
      finish(const OAuthPopupResult(completed: false));
    }
  });

  return completer.future;
}

OAuthPopupResult? _parseOAuthMessage(JSAny? rawData, String expectedProvider) {
  final dartData = rawData?.dartify();
  if (dartData is! Map) return null;
  if (dartData['type'] != 'veraxi_oauth_callback') return null;
  if (dartData['provider'] != expectedProvider) return null;

  final status = dartData['status'] as String?;
  if (status == 'connected') {
    return const OAuthPopupResult(completed: true);
  }
  final error = dartData['error'] as String?;
  return OAuthPopupResult(
    completed: false,
    error: (error != null && error.isNotEmpty) ? error : 'oauth_failed',
  );
}
