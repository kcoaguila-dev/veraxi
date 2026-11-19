import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/view_models/landing_demo_view_model.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// The hero demo: pick a sample question, then select a highlighted phrase
/// in the answer to see the passages and the path behind it.
class AnswerDemo extends ConsumerWidget {
  const AnswerDemo({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(landingDemoProvider);
    final viewModel = ref.read(landingDemoProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Illustration with sample documents, not live data. Pick a '
          'question, then select a highlighted phrase to see where it came '
          'from.',
          style: LandingType.sans(
            size: 15,
            color: LandingColors.grey,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        _QuestionPicker(
          selected: state.question,
          onSelect: viewModel.selectQuestion,
        ),
        const SizedBox(height: 20),
        LandingColumns(
          gap: 28,
          children: [
            _AnswerPanel(state: state, onSelectClaim: viewModel.selectClaim),
            _SourcesColumn(question: state.activeQuestion, claim: state.claim),
          ],
        ),
      ],
    );
  }
}

class _QuestionPicker extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;

  const _QuestionPicker({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columns = constraints.maxWidth >= 840 ? 3 : 1;
        final itemWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < kDemoQuestions.length; i++)
              SizedBox(
                width: itemWidth,
                child: _QuestionButton(
                  label: kDemoQuestions[i].question,
                  selected: i == selected,
                  onTap: () => onSelect(i),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _QuestionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _QuestionButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: const BorderSide(color: LandingColors.ink, width: 1.5),
    );

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? LandingColors.ink : Colors.transparent,
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          focusColor: LandingColors.cobalt.withValues(alpha: 0.3),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  style: LandingType.sans(
                    size: 17,
                    weight: FontWeight.w600,
                    color: selected ? LandingColors.paper : LandingColors.ink,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnswerPanel extends StatelessWidget {
  final LandingDemoState state;
  final ValueChanged<int> onSelectClaim;

  const _AnswerPanel({required this.state, required this.onSelectClaim});

  @override
  Widget build(BuildContext context) {
    final wide = LandingLayout.isWide(context);
    final question = state.activeQuestion;
    final claim = question.claims[state.claim];
    final answerStyle = LandingType.serif(size: wide ? 26 : 21, height: 1.62);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final spans = <InlineSpan>[];
    for (final segment in question.segments) {
      final index = segment.claim;
      if (index == null) {
        spans.add(TextSpan(text: segment.text));
        continue;
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _ClaimChip(
            // A new key per question restarts the highlighter sweep. Changing
            // only the selected phrase keeps the same key, so it does not.
            key: ValueKey('q${state.question}-c$index'),
            label: segment.text,
            index: index,
            active: index == state.claim,
            textStyle: answerStyle,
            reduceMotion: reduceMotion,
            onTap: () => onSelectClaim(index),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(wide ? 40 : 24),
      decoration: BoxDecoration(
        color: LandingColors.panel,
        border: Border.all(color: LandingColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(style: answerStyle, children: spans)),
          const SizedBox(height: 32),
          Text(
            'How Veraxi got there',
            style: LandingType.sans(size: 16, weight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          for (final chain in claim.chains)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PathChain(chain: chain),
            ),
          const SizedBox(height: 4),
          Text(
            claim.note,
            style: LandingType.sans(
              size: 15,
              color: LandingColors.grey,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// A phrase in the answer with a highlighter mark behind it.
class _ClaimChip extends StatefulWidget {
  final String label;
  final int index;
  final bool active;
  final TextStyle textStyle;
  final bool reduceMotion;
  final VoidCallback onTap;

  const _ClaimChip({
    super.key,
    required this.label,
    required this.index,
    required this.active,
    required this.textStyle,
    required this.reduceMotion,
    required this.onTap,
  });

  @override
  State<_ClaimChip> createState() => _ClaimChipState();
}

class _ClaimChipState extends State<_ClaimChip> {
  static const List<String> _superscripts = ['¹', '²', '³'];
  static const int _sweepMs = 900;

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final delayMs = 150 + 350 * widget.index;
    final totalMs = delayMs + _sweepMs;
    final reduce = widget.reduceMotion;

    // The focus ring has to be drawn here: the highlighter paints above the
    // ink layer, so the default InkWell focus color would be hidden.
    Border? border;
    if (_focused) {
      border = Border.all(color: LandingColors.cobalt, width: 2);
    } else if (widget.active) {
      border = const Border(
        bottom: BorderSide(color: LandingColors.cobalt, width: 2),
      );
    }

    final number =
        widget.index < _superscripts.length ? _superscripts[widget.index] : '';

    final label = Semantics(
      button: true,
      selected: widget.active,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (focused) => setState(() => _focused = focused),
        borderRadius: BorderRadius.circular(2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(border: border),
          child: Text.rich(
            TextSpan(
              style: widget.textStyle,
              children: [
                TextSpan(text: widget.label),
                TextSpan(
                  text: number,
                  style: LandingType.sans(
                    size: 14,
                    weight: FontWeight.w600,
                    color: LandingColors.cobalt,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: reduce ? 1.0 : 0.0, end: 1.0),
      duration: reduce ? Duration.zero : Duration(milliseconds: totalMs),
      curve: reduce
          ? Curves.linear
          : Interval(delayMs / totalMs, 1.0, curve: Curves.easeOutCubic),
      child: label,
      builder: (context, t, child) {
        return Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: FractionallySizedBox(
                  widthFactor: t,
                  heightFactor: widget.active ? 0.84 : 0.36,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      color: LandingColors.highlight,
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            child!,
          ],
        );
      },
    );
  }
}

class _PathChain extends StatelessWidget {
  final List<String> chain;

  const _PathChain({required this.chain});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < chain.length; i++) ...[
          if (i > 0)
            const Icon(
              Icons.arrow_forward,
              size: 18,
              color: LandingColors.cobalt,
            ),
          _PathNode(label: chain[i]),
        ],
      ],
    );
  }
}

class _PathNode extends StatelessWidget {
  final String label;

  const _PathNode({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: LandingColors.panel,
        border: Border.all(color: LandingColors.nodeLine),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: LandingType.sans(size: 14, height: 1.3),
      ),
    );
  }
}

class _SourcesColumn extends StatelessWidget {
  final DemoQuestion question;
  final int claim;

  const _SourcesColumn({required this.question, required this.claim});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Passages it read',
          style: LandingType.sans(size: 16, weight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        for (final source in question.sources)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _SourceCard(source: source, claim: claim),
          ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  final DemoSource source;
  final int claim;

  const _SourceCard({required this.source, required this.claim});

  @override
  Widget build(BuildContext context) {
    final used = source.passages.any((p) => p.claims.contains(claim));
    // The border grows by one pixel when the card is used; the padding shrinks
    // by the same amount so the card does not change size.
    final borderWidth = used ? 2.0 : 1.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(21 - borderWidth),
      decoration: BoxDecoration(
        color: LandingColors.panel,
        border: Border.all(
          color: used ? LandingColors.cobalt : LandingColors.line,
          width: borderWidth,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                source.name,
                style: LandingType.sans(size: 15, weight: FontWeight.w700),
              ),
              Text(
                source.where,
                style: LandingType.sans(size: 14, color: LandingColors.grey),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final passage in source.passages)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text.rich(
                TextSpan(
                  style: LandingType.serif(size: 16, height: 1.6),
                  children: [
                    TextSpan(text: passage.before),
                    TextSpan(
                      text: passage.hit,
                      style: passage.claims.contains(claim)
                          ? const TextStyle(
                              backgroundColor: LandingColors.highlight,
                            )
                          : null,
                    ),
                    TextSpan(text: passage.after),
                  ],
                ),
              ),
            ),
          if (used)
            Text(
              'Used for the selected phrase',
              style: LandingType.sans(
                size: 14,
                weight: FontWeight.w600,
                color: LandingColors.cobalt,
              ),
            ),
        ],
      ),
    );
  }
}
