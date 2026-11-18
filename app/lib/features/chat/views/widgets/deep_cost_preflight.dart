import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/deep_cost_view_model.dart';

/// Live pre-flight chip: watches [deepCostEstimateProvider] for
/// [model] and renders nothing until (and unless) an estimate
/// arrives. Shown by chat_input.dart only while Deep
/// (High-Accuracy / agentic debate) mode is on.
class DeepCostPreflight extends ConsumerWidget {
  final String? model;

  const DeepCostPreflight({super.key, required this.model});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estimate = ref.watch(deepCostEstimateProvider(model));
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: estimate == null
            ? const SizedBox.shrink(key: ValueKey('deep-cost-empty'))
            : Padding(
                key: const ValueKey('deep-cost-chip'),
                padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DeepCostPreflightChip(estimate: estimate),
                ),
              ),
      ),
    );
  }
}

/// Presentational chip for one [DeepCostEstimate].
///
/// The token range always renders. The USD range renders ONLY when
/// [DeepCostEstimate.estimatedCostUsd] is non-null — unknown pricing
/// shows no dollar figure at all, never an invented $0.00.
class DeepCostPreflightChip extends StatelessWidget {
  final DeepCostEstimate estimate;

  const DeepCostPreflightChip({super.key, required this.estimate});

  static final NumberFormat _tokens = NumberFormat.decimalPattern();
  static final NumberFormat _usd = NumberFormat.currency(symbol: '\$');

  String _range(DeepCostRange range, NumberFormat format) =>
      '${format.format(range.min)}–${format.format(range.max)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();
    final accent = ext?.primaryGradientStart ?? const Color(0xFF8B7CF6);
    final cost = estimate.estimatedCostUsd;
    final summary = StringBuffer()
      ..write(_range(estimate.llmCalls, _tokens))
      ..write(' calls · ')
      ..write(_range(estimate.totalTokens, _tokens))
      ..write(' tokens');
    if (cost != null) {
      summary
        ..write(' · ')
        ..write(_range(cost, _usd));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: ext?.cardBackground ?? const Color(0xFF222226),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: ext?.borderColor ?? const Color(0xFF2E2E34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            'Deep estimate',
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              summary.toString(),
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: ext?.textTertiary ?? Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
