/// Outcome of an in-browser OAuth popup flow.
class OAuthPopupResult {
  final bool completed;
  final String? error;

  const OAuthPopupResult({
    required this.completed,
    this.error,
  });
}
