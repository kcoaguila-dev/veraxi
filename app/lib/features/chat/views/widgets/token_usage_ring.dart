import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';

/// Circular context-usage gauge for the chat composer, following the
/// ring pattern used by LibreChat's context gauge and the composer
/// rings in Kindo / Libre WebUI: the arc shows how full the selected
/// model's context window is (latest prompt tokens / window), coloured
/// green below 70%, amber 70–89%, red at 90%+.
///
/// When the model's window is unknown the ring is dashed and its centre
/// shows the context token count instead of a percentage — counts are
/// still real, a denominator is never invented. Tapping opens a
/// breakdown sheet with last-response and whole-conversation totals.
/// Severity colour shared by the ring, the bar, and the breakdown
/// sheet: green below 70% full, amber 70–89%, red at 90%+. A null
/// fraction (window unknown) is neutral grey.
Color tokenUsageSeverityColor(double? fraction) {
  if (fraction == null) return const Color(0xFF8A8A8A);
  if (fraction >= 0.9) return const Color(0xFFEF4444);
  if (fraction >= 0.7) return const Color(0xFFF59E0B);
  return const Color(0xFF22C55E);
}

class TokenUsageRing extends StatelessWidget {
  final TokenUsageSummary usage;

  /// Current indicator form + change callback, forwarded to the
  /// breakdown sheet's display-style switcher. Optional so the ring
  /// can render standalone (tests, previews).
  final TokenUsageIndicatorStyle? indicatorStyle;
  final ValueChanged<TokenUsageIndicatorStyle>? onIndicatorStyleChanged;

  /// Opens the manual-compaction flow (owned by the chat screen,
  /// which has the view model). Null hides the sheet's Compact
  /// button (standalone rendering, local threads).
  final VoidCallback? onCompactPressed;

  const TokenUsageRing({
    super.key,
    required this.usage,
    this.indicatorStyle,
    this.onIndicatorStyleChanged,
    this.onCompactPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = usage.contextFraction;
    final centerLabel = fraction != null
        ? '${(fraction * 100).round()}%'
        : formatTokenCount(usage.contextTokens ?? usage.sessionTotalTokens);
    final tooltip = fraction != null
        ? 'Context ${(fraction * 100).round()}% full — tap for token usage'
        : 'Token usage — tap for details';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => showTokenUsageBreakdown(
          context,
          usage,
          indicatorStyle: indicatorStyle,
          onIndicatorStyleChanged: onIndicatorStyleChanged,
          onCompactPressed: onCompactPressed,
        ),
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 36,
          height: 36,
          child: CustomPaint(
            painter: _RingPainter(
              fraction: fraction,
              color: tokenUsageSeverityColor(fraction),
              trackColor: const Color(0xFF2E2E2E),
            ),
            child: Center(
              child: Text(
                centerLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

/// Linear context-usage bar: the alternative indicator form, placed
/// as a slim strip directly above the composer (the placement Theia
/// and LibreChat use for a bar). Where the ring encodes the fraction
/// as an arc, the bar prints the truth as text — "41,203 / 128,000 ·
/// 32%" — because users who build their own indicators (Claude Code
/// statuslines) overwhelmingly choose a bar plus printed counts.
///
/// When the window is unknown the track stays empty and the text
/// shows the real token count only; a fill is never fabricated.
/// Tapping opens the same breakdown sheet as the ring.
class TokenUsageBar extends StatelessWidget {
  final TokenUsageSummary usage;
  final TokenUsageIndicatorStyle? indicatorStyle;
  final ValueChanged<TokenUsageIndicatorStyle>? onIndicatorStyleChanged;
  final VoidCallback? onCompactPressed;

  const TokenUsageBar({
    super.key,
    required this.usage,
    this.indicatorStyle,
    this.onIndicatorStyleChanged,
    this.onCompactPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = usage.contextFraction;
    final label = fraction != null
        ? '${formatTokenCountFull(usage.contextTokens!)} / '
            '${formatTokenCountFull(usage.contextWindowTokens!)} · '
            '${(fraction * 100).round()}%'
        : '${formatTokenCountFull(usage.contextTokens ?? usage.sessionTotalTokens)} tokens';
    return Material(
      color: const Color(0xFF141414),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showTokenUsageBreakdown(
          context,
          usage,
          indicatorStyle: indicatorStyle,
          onIndicatorStyleChanged: onIndicatorStyleChanged,
          onCompactPressed: onCompactPressed,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: fraction ?? 0,
                    backgroundColor: const Color(0xFF2E2E2E),
                    valueColor: AlwaysStoppedAnimation<Color>(
                        tokenUsageSeverityColor(fraction)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double? fraction;
  final Color color;
  final Color trackColor;

  const _RingPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 3.5;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, track);
    if (fraction == null) {
      _paintDashedArc(canvas, center, radius, strokeWidth);
      return;
    }
    if (fraction! <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction!,
      false,
      arc,
    );
  }

  void _paintDashedArc(
      Canvas canvas, Offset center, double radius, double strokeWidth) {
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color;
    const dashAngle = 0.32;
    const gapAngle = 0.26;
    var start = -math.pi / 2;
    final end = start + 2 * math.pi;
    while (start < end) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        dashAngle,
        false,
        dash,
      );
      start += dashAngle + gapAngle;
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      color != oldDelegate.color ||
      trackColor != oldDelegate.trackColor;
}

/// Bottom-sheet breakdown opened from the ring or the bar: context
/// window state, the last response's usage, and whole-conversation
/// totals. Cost lines appear only when the backend could price the
/// model. When [onIndicatorStyleChanged] is provided, the sheet also
/// carries the Ring / Bar / Off display switcher; the same switcher
/// lives permanently in the chat header menu, so choosing Off here
/// is always reversible from the header.
Future<void> showTokenUsageBreakdown(
  BuildContext context,
  TokenUsageSummary usage, {
  TokenUsageIndicatorStyle? indicatorStyle,
  ValueChanged<TokenUsageIndicatorStyle>? onIndicatorStyleChanged,
  VoidCallback? onCompactPressed,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => _TokenUsageBreakdown(
      usage: usage,
      indicatorStyle: indicatorStyle,
      onIndicatorStyleChanged: onIndicatorStyleChanged,
      onCompactPressed: onCompactPressed,
    ),
  );
}

class _TokenUsageBreakdown extends StatelessWidget {
  final TokenUsageSummary usage;
  final TokenUsageIndicatorStyle? indicatorStyle;
  final ValueChanged<TokenUsageIndicatorStyle>? onIndicatorStyleChanged;
  final VoidCallback? onCompactPressed;

  const _TokenUsageBreakdown({
    required this.usage,
    this.indicatorStyle,
    this.onIndicatorStyleChanged,
    this.onCompactPressed,
  });

  /// Compaction is offered once the context is at least half full
  /// (or large in absolute terms when the window is unknown) —
  /// earlier than that there is rarely enough worth summarizing,
  /// and the server gates refuse trivial compactions anyway.
  bool get _canCompact =>
      onCompactPressed != null &&
      ((usage.contextFraction ?? 0) >= 0.5 ||
          (usage.contextTokens ?? 0) >= 20000);

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>();
    final fraction = usage.contextFraction;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.data_usage_outlined,
                      size: 18,
                      color: ext?.primaryGradientStart ?? Colors.white),
                  const SizedBox(width: 8),
                  const Text(
                    'Token Usage',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (fraction != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: fraction,
                    backgroundColor: const Color(0xFF2E2E2E),
                    valueColor: AlwaysStoppedAnimation<Color>(
                        tokenUsageSeverityColor(fraction)),
                  ),
                ),
                const SizedBox(height: 10),
                _row(
                  'Context window',
                  '${formatTokenCountFull(usage.contextTokens!)} of '
                      '${formatTokenCountFull(usage.contextWindowTokens!)} '
                      'tokens · ${formatTokenCountFull(usage.contextTokensRemaining!)} left',
                ),
              ] else
                _row(
                  'Context window',
                  usage.contextTokens != null
                      ? '${formatTokenCountFull(usage.contextTokens!)} tokens '
                          '(window size unknown for this model)'
                      : 'Window size unknown for this model',
                ),
              if (usage.hasBreakdown && usage.breakdownTotal > 0) ...[
                const SizedBox(height: 14),
                const Text(
                  'WHAT FILLS IT · LAST REQUEST',
                  style: TextStyle(
                    color: Color(0xFF8A8A8A),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Row(
                    children: [
                      for (final segment in _segments(usage))
                        if (segment.tokens > 0)
                          Expanded(
                            flex: segment.tokens,
                            child: Container(height: 8, color: segment.color),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                for (final segment in _segments(usage))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: segment.color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          segment.label,
                          style: const TextStyle(
                              color: Color(0xFFB0B0B0), fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          formatTokenCountFull(segment.tokens),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              _row(
                'Last response',
                'Prompt ${_fmt(usage.lastPromptTokens)} · '
                    'Completion ${_fmt(usage.lastCompletionTokens)} · '
                    'Total ${_fmt(usage.lastTotalTokens)}',
              ),
              if (usage.lastEstimatedCostUsd != null)
                _row('Last est. cost',
                    '\$${usage.lastEstimatedCostUsd!.toStringAsFixed(4)}'),
              const SizedBox(height: 14),
              _row(
                'This conversation',
                'Prompt ${formatTokenCountFull(usage.sessionPromptTokens)} · '
                    'Completion ${formatTokenCountFull(usage.sessionCompletionTokens)} · '
                    'Total ${formatTokenCountFull(usage.sessionTotalTokens)} '
                    'tokens · ${usage.responseCount} '
                    '${usage.responseCount == 1 ? 'response' : 'responses'}',
              ),
              if (usage.hasSessionCost)
                _row('Conversation est. cost',
                    '\$${usage.sessionEstimatedCostUsd.toStringAsFixed(4)}'),
              if (_canCompact) ...[
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onCompactPressed!();
                    },
                    icon: const Icon(Icons.compress, size: 16),
                    label: const Text('Compact conversation…'),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Summarize earlier messages to free context. '
                  'You review and edit the summary before anything changes.',
                  style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
                ),
              ],
              if (indicatorStyle != null &&
                  onIndicatorStyleChanged != null) ...[
                const SizedBox(height: 18),
                const Text(
                  'INDICATOR STYLE',
                  style: TextStyle(
                    color: Color(0xFF8A8A8A),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TokenUsageIndicatorStyle>(
                  segments: const [
                    ButtonSegment(
                      value: TokenUsageIndicatorStyle.ring,
                      label: Text('Ring'),
                      icon: Icon(Icons.donut_large_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: TokenUsageIndicatorStyle.bar,
                      label: Text('Bar'),
                      icon: Icon(Icons.linear_scale, size: 16),
                    ),
                    ButtonSegment(
                      value: TokenUsageIndicatorStyle.off,
                      label: Text('Off'),
                      icon: Icon(Icons.visibility_off_outlined, size: 16),
                    ),
                  ],
                  selected: {indicatorStyle!},
                  onSelectionChanged: (selection) {
                    onIndicatorStyleChanged!(selection.first);
                    Navigator.of(context).pop();
                  },
                  style: SegmentedButton.styleFrom(
                    foregroundColor: const Color(0xFFB0B0B0),
                    selectedForegroundColor: Colors.white,
                    selectedBackgroundColor: const Color(0xFF2E2E2E),
                    backgroundColor: const Color(0xFF1C1C1C),
                    side: const BorderSide(color: Color(0xFF2E2E2E)),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(int? value) => value == null ? '--' : formatTokenCountFull(value);

  /// The four context segments with their display colours, in
  /// stacking order. Colours are categorical (this bar answers
  /// "what fills it"), deliberately distinct from the severity
  /// colours used by the ring/bar.
  List<({String label, int tokens, Color color})> _segments(
      TokenUsageSummary usage) {
    return [
      (
        label: 'System',
        tokens: usage.contextSystemTokens ?? 0,
        color: const Color(0xFF5B8DEF),
      ),
      (
        label: 'Tools',
        tokens: usage.contextToolsTokens ?? 0,
        color: const Color(0xFF9B7EDE),
      ),
      (
        label: 'Tool results (incl. retrieved)',
        tokens: usage.contextToolResultsTokens ?? 0,
        color: const Color(0xFF3BA272),
      ),
      (
        label: 'Messages',
        tokens: usage.contextMessagesTokens ?? 0,
        color: const Color(0xFFD9A441),
      ),
    ];
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFF8A8A8A),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
