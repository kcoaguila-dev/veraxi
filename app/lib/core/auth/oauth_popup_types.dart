/// Outcome of an in-browser OAuth popup flow.
class OAuthPopupResult {
  final bool completed;
  final bool pending;
  final String? error;

  const OAuthPopupResult({
    required this.completed,
    this.pending = false,
    this.error,
  });
}
