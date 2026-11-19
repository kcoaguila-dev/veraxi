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
class TokenUsageRing extends StatelessWidget {
  final TokenUsageSummary usage;

  const TokenUsageRing({super.key, required this.usage});

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
        onTap: () => showTokenUsageBreakdown(context, usage),
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 36,
          height: 36,
          child: CustomPaint(
            painter: _RingPainter(
              fraction: fraction,
              color: _arcColor(fraction),
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

  Color _arcColor(double? fraction) {
    if (fraction == null) return const Color(0xFF8A8A8A);
    if (fraction >= 0.9) return const Color(0xFFEF4444);
    if (fraction >= 0.7) return const Color(0xFFF59E0B);
    return const Color(0xFF22C55E);
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

/// Bottom-sheet breakdown opened from the ring: context window state,
/// the last response's usage, and whole-conversation totals. Cost
/// lines appear only when the backend could price the model.
Future<void> showTokenUsageBreakdown(
    BuildContext context, TokenUsageSummary usage) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => _TokenUsageBreakdown(usage: usage),
  );
}

class _TokenUsageBreakdown extends StatelessWidget {
  final TokenUsageSummary usage;

  const _TokenUsageBreakdown({required this.usage});

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
                    valueColor:
                        AlwaysStoppedAnimation<Color>(_barColor(fraction)),
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
            ],
          ),
        ),
      ),
    );
  }

  Color _barColor(double fraction) {
    if (fraction >= 0.9) return const Color(0xFFEF4444);
    if (fraction >= 0.7) return const Color(0xFFF59E0B);
    return const Color(0xFF22C55E);
  }

  String _fmt(int? value) => value == null ? '--' : formatTokenCountFull(value);

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
