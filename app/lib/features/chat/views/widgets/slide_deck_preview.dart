import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/chat/view_models/slide_deck_provider.dart';

/// Interactive slide-deck viewer for `create_office_artifact` (`format: pptx`)
/// payloads: left 16:9 thumbnail rail, centered 16:9 slide canvas, keyboard
/// arrow navigation, `+ Add slide` hook, and fullscreen Present mode.
class SlideDeckPreview extends StatefulWidget {
  final SlideDeck deck;

  /// Invoked when the user clicks `+ Add slide`. When null, the button is
  /// hidden so read-only previews never show dead controls.
  final VoidCallback? onAddSlide;

  /// Invoked with the user's free-text request from the floating
  /// `Ask Veraxi` bar (Claude's bottom quick-action bar). When null,
  /// the bar is hidden so read-only previews never show dead controls.
  final ValueChanged<String>? onAskVeraxi;

  const SlideDeckPreview({
    super.key,
    required this.deck,
    this.onAddSlide,
    this.onAskVeraxi,
  });

  @override
  State<SlideDeckPreview> createState() => _SlideDeckPreviewState();
}

class _SlideDeckPreviewState extends State<SlideDeckPreview> {
  int _selectedIndex = 0;
  bool _showNotes = false;

  /// Stage zoom: 1.0 is fit-to-stage; the indicator in the control
  /// pill shows the percentage, like Claude's `46%` zoom readout.
  double _zoom = 1.0;
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _askController = TextEditingController();

  void _stepZoom(double delta) {
    setState(() => _zoom = (_zoom + delta).clamp(0.5, 2.0));
  }

  void _submitAsk() {
    final text = _askController.text.trim();
    if (text.isEmpty || widget.onAskVeraxi == null) return;
    widget.onAskVeraxi!(text);
    _askController.clear();
  }

  @override
  void didUpdateWidget(covariant SlideDeckPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIdx = widget.deck.slides.length - 1;
    if (_selectedIndex > maxIdx) {
      _selectedIndex = maxIdx < 0 ? 0 : maxIdx;
    } else if (widget.deck.slides.length > oldWidget.deck.slides.length) {
      // Jump to newly appended slide.
      _selectedIndex = widget.deck.slides.length - 1;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _askController.dispose();
    super.dispose();
  }

  void _stepSlide(int delta) {
    final next = _selectedIndex + delta;
    if (next < 0 || next >= widget.deck.slides.length) return;
    setState(() => _selectedIndex = next);
  }

  void _openPresentation() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _SlidePresentationDialog(
        deck: widget.deck,
        initialIndex: _selectedIndex,
        onIndexChanged: (idx) {
          if (mounted) setState(() => _selectedIndex = idx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.deck.slides;
    final activeSlide = slides[_selectedIndex];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _stepSlide(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _stepSlide(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _stepSlide(-1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _stepSlide(-1),
      },
      child: Focus(
        focusNode: _focusNode,
        child: GestureDetector(
          onTap: () => _focusNode.requestFocus(),
          behavior: HitTestBehavior.translucent,
          child: Container(
            color: const Color(0xFF141416),
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showRail = constraints.maxWidth >= 500;
                      return Row(
                        children: [
                          if (showRail)
                            _ThumbnailRail(
                              slides: slides,
                              selectedIndex: _selectedIndex,
                              onSelect: (i) =>
                                  setState(() => _selectedIndex = i),
                              onAddSlide: widget.onAddSlide,
                            ),
                          Expanded(
                            child: _SlideStage(
                              slide: activeSlide,
                              slideIndex: _selectedIndex,
                              totalSlides: slides.length,
                              showNotes: _showNotes,
                              zoom: _zoom,
                              onZoomIn: () => _stepZoom(0.1),
                              onZoomOut: () => _stepZoom(-0.1),
                              onZoomFit: () => setState(() => _zoom = 1.0),
                              onToggleNotes: activeSlide.notes != null
                                  ? () =>
                                      setState(() => _showNotes = !_showNotes)
                                  : null,
                              onPrev: _selectedIndex > 0
                                  ? () => _stepSlide(-1)
                                  : null,
                              onNext: _selectedIndex < slides.length - 1
                                  ? () => _stepSlide(1)
                                  : null,
                              onPresent: _openPresentation,
                              onAddSlide: showRail ? null : widget.onAddSlide,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (widget.onAskVeraxi != null)
                  _AskVeraxiBar(
                    controller: _askController,
                    onSubmit: _submitAsk,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbnailRail extends StatelessWidget {
  final List<SlideItem> slides;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback? onAddSlide;

  const _ThumbnailRail({
    required this.slides,
    required this.selectedIndex,
    required this.onSelect,
    this.onAddSlide,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      decoration: const BoxDecoration(
        color: Color(0xFF111113),
        border: Border(right: BorderSide(color: Color(0xFF262629))),
      ),
      child: Column(
        children: [
          if (onAddSlide != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onAddSlide,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('Add slide'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE2E8F0),
                    side: const BorderSide(color: Color(0xFF323238)),
                    backgroundColor: const Color(0xFF1A1A1E),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: slides.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _SlideThumbnailTile(
                slide: slides[index],
                index: index,
                isSelected: index == selectedIndex,
                onTap: () => onSelect(index),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideThumbnailTile extends StatelessWidget {
  final SlideItem slide;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  const _SlideThumbnailTile({
    required this.slide,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _SlidePalette.resolve(slide, index);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? const Color(0xFFE2E8F0)
                      : const Color(0xFF71717A),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: palette.background,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF4F8EF7)
                        : const Color(0xFF2E2E34),
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      slide.title.isEmpty ? 'Slide ${index + 1}' : slide.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: palette.foreground,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 18,
                      height: 2,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideStage extends StatelessWidget {
  final SlideItem slide;
  final int slideIndex;
  final int totalSlides;
  final bool showNotes;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomFit;
  final VoidCallback? onToggleNotes;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onPresent;
  final VoidCallback? onAddSlide;

  const _SlideStage({
    required this.slide,
    required this.slideIndex,
    required this.totalSlides,
    required this.showNotes,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomFit,
    required this.onToggleNotes,
    required this.onPrev,
    required this.onNext,
    required this.onPresent,
    this.onAddSlide,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Transform.scale(
                  scale: zoom,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _SlideCanvas(
                      key: ValueKey('slide-$slideIndex-${slide.title}'),
                      slide: slide,
                      slideIndex: slideIndex,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showNotes && slide.notes != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1D1D21),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2D2D33)),
            ),
            child: Text(
              slide.notes!,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ).animate().fadeIn(duration: 150.ms),
        Padding(
          padding: const EdgeInsets.only(bottom: 14, top: 4),
          child: _DeckControlPill(
            slideIndex: slideIndex,
            totalSlides: totalSlides,
            onPrev: onPrev,
            onNext: onNext,
            onPresent: onPresent,
            onToggleNotes: onToggleNotes,
            showNotes: showNotes,
            onAddSlide: onAddSlide,
            zoom: zoom,
            onZoomIn: onZoomIn,
            onZoomOut: onZoomOut,
            onZoomFit: onZoomFit,
          ),
        ),
      ],
    );
  }
}

class _SlideCanvas extends StatelessWidget {
  final SlideItem slide;
  final int slideIndex;

  const _SlideCanvas({
    super.key,
    required this.slide,
    required this.slideIndex,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _SlidePalette.resolve(slide, slideIndex);
    final isTitleOnly =
        slide.subtitle == null && slide.bullets.isEmpty && slide.table == null;

    return Container(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = (constraints.maxWidth / 640).clamp(0.55, 1.8);
          final hPad = 42.0 * scale;
          final vPad = 32.0 * scale;

          return Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
            child: isTitleOnly
                ? _buildHeroLayout(palette, scale)
                : _buildContentLayout(palette, scale),
          );
        },
      ),
    );
  }

  Widget _buildHeroLayout(_SlidePalette palette, double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          slide.title,
          style: GoogleFonts.inter(
            color: palette.foreground,
            fontSize: 44 * scale,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
            height: 1.12,
          ),
        ),
        SizedBox(height: 16 * scale),
        Container(
          width: 56 * scale,
          height: 4.5 * scale,
          decoration: BoxDecoration(
            color: palette.accent,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ],
    );
  }

  Widget _buildContentLayout(_SlidePalette palette, double scale) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            slide.title,
            style: GoogleFonts.inter(
              color: palette.foreground,
              fontSize: 28 * scale,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              height: 1.2,
            ),
          ),
          SizedBox(height: 10 * scale),
          Container(
            width: 44 * scale,
            height: 3.5 * scale,
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          if (slide.subtitle != null) ...[
            SizedBox(height: 12 * scale),
            Text(
              slide.subtitle!,
              style: GoogleFonts.inter(
                color: palette.muted,
                fontSize: 16 * scale,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ],
          if (slide.bullets.isNotEmpty) ...[
            SizedBox(height: 16 * scale),
            for (final bullet in slide.bullets)
              Padding(
                padding: EdgeInsets.only(bottom: 8 * scale),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding:
                          EdgeInsets.only(top: 6 * scale, right: 10 * scale),
                      child: Container(
                        width: 6 * scale,
                        height: 6 * scale,
                        decoration: BoxDecoration(
                          color: palette.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        bullet,
                        style: GoogleFonts.inter(
                          color: palette.foreground.withValues(alpha: 0.92),
                          fontSize: 15 * scale,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (slide.table != null) ...[
            SizedBox(height: 14 * scale),
            _SlideTableView(
              table: slide.table!,
              palette: palette,
              scale: scale,
            ),
          ],
        ],
      ),
    );
  }
}

class _SlideTableView extends StatelessWidget {
  final SlideTable table;
  final _SlidePalette palette;
  final double scale;

  const _SlideTableView({
    required this.table,
    required this.palette,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        border: TableBorder.symmetric(
          inside: BorderSide(color: palette.border, width: 0.75),
        ),
        children: [
          if (table.headers.isNotEmpty)
            TableRow(
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.16),
              ),
              children: [
                for (final h in table.headers)
                  Padding(
                    padding: EdgeInsets.all(8 * scale),
                    child: Text(
                      h,
                      style: GoogleFonts.inter(
                        color: palette.foreground,
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          for (final row in table.rows)
            TableRow(
              children: [
                for (final cell in row)
                  Padding(
                    padding: EdgeInsets.all(8 * scale),
                    child: Text(
                      cell,
                      style: GoogleFonts.inter(
                        color: palette.muted,
                        fontSize: 12 * scale,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DeckControlPill extends StatelessWidget {
  final int slideIndex;
  final int totalSlides;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onPresent;
  final VoidCallback? onToggleNotes;
  final bool showNotes;
  final VoidCallback? onAddSlide;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomFit;

  const _DeckControlPill({
    required this.slideIndex,
    required this.totalSlides,
    required this.onPrev,
    required this.onNext,
    required this.onPresent,
    required this.onToggleNotes,
    required this.showNotes,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomFit,
    this.onAddSlide,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF323238)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous slide',
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left, size: 18),
            visualDensity: VisualDensity.compact,
            color: const Color(0xFFE2E8F0),
            disabledColor: const Color(0xFF52525B),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${slideIndex + 1} / $totalSlides',
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next slide',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right, size: 18),
            visualDensity: VisualDensity.compact,
            color: const Color(0xFFE2E8F0),
            disabledColor: const Color(0xFF52525B),
          ),
          const SizedBox(width: 4),
          Container(width: 1, height: 16, color: const Color(0xFF323238)),
          const SizedBox(width: 4),
          if (onAddSlide != null)
            IconButton(
              tooltip: 'Add slide',
              onPressed: onAddSlide,
              icon: const Icon(Icons.add, size: 17),
              visualDensity: VisualDensity.compact,
              color: const Color(0xFFE2E8F0),
            ),
          if (onToggleNotes != null)
            IconButton(
              tooltip: showNotes ? 'Hide speaker notes' : 'Show speaker notes',
              onPressed: onToggleNotes,
              icon: Icon(
                Icons.sticky_note_2_outlined,
                size: 16,
                color: showNotes
                    ? const Color(0xFFD98A2B)
                    : const Color(0xFFA1A1AA),
              ),
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            tooltip: 'Present fullscreen',
            onPressed: onPresent,
            icon: const Icon(Icons.play_arrow_rounded, size: 19),
            visualDensity: VisualDensity.compact,
            color: const Color(0xFFE2E8F0),
          ),
          const SizedBox(width: 4),
          Container(width: 1, height: 16, color: const Color(0xFF323238)),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove, size: 16),
            visualDensity: VisualDensity.compact,
            color: const Color(0xFFE2E8F0),
          ),
          InkWell(
            onTap: onZoomFit,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                '${(zoom * 100).round()}%',
                style: const TextStyle(
                  color: Color(0xFFE2E8F0),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
            icon: const Icon(Icons.add, size: 16),
            visualDensity: VisualDensity.compact,
            color: const Color(0xFFE2E8F0),
          ),
        ],
      ),
    );
  }
}

/// Bottom floating quick-action bar: a compact prompt field that
/// sends a free-text edit request for the deck to the chat
/// (Claude's `Ask Claude` bar, here `Ask Veraxi`).
class _AskVeraxiBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  const _AskVeraxiBar({required this.controller, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF323238)),
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome_outlined,
                size: 16, color: Color(0xFFD98A2B)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onSubmitted: (_) => onSubmit(),
                style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Ask Veraxi to edit this deck…',
                  hintStyle: TextStyle(color: Color(0xFF71717A), fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Ask Veraxi',
              onPressed: onSubmit,
              icon: const Icon(Icons.arrow_upward, size: 16),
              visualDensity: VisualDensity.compact,
              color: const Color(0xFFE2E8F0),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlidePresentationDialog extends StatefulWidget {
  final SlideDeck deck;
  final int initialIndex;
  final ValueChanged<int> onIndexChanged;

  const _SlidePresentationDialog({
    required this.deck,
    required this.initialIndex,
    required this.onIndexChanged,
  });

  @override
  State<_SlidePresentationDialog> createState() =>
      _SlidePresentationDialogState();
}

class _SlidePresentationDialogState extends State<_SlidePresentationDialog> {
  late int _index = widget.initialIndex;

  void _step(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.deck.slides.length) return;
    setState(() => _index = next);
    widget.onIndexChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.deck.slides;
    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0A0A0C),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: _SlideCanvas(
                        key: ValueKey('present-$_index'),
                        slide: slides[_index],
                        slideIndex: _index,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 20,
                child: IconButton(
                  tooltip: 'Exit presentation',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ),
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C20),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF323238)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _index > 0 ? () => _step(-1) : null,
                          icon: const Icon(Icons.chevron_left),
                          color: Colors.white,
                          disabledColor: Colors.white24,
                        ),
                        Text(
                          '${_index + 1} / ${slides.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        IconButton(
                          onPressed: _index < slides.length - 1
                              ? () => _step(1)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                          color: Colors.white,
                          disabledColor: Colors.white24,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlidePalette {
  final Color background;
  final Color foreground;
  final Color muted;
  final Color accent;
  final Color border;

  const _SlidePalette({
    required this.background,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.border,
  });

  factory _SlidePalette.resolve(SlideItem slide, int index) {
    final theme = slide.theme?.trim().toLowerCase();
    final isDark = theme == 'dark' || (theme != 'light' && index == 0);
    final accent = _parseHexColor(slide.accentColor) ?? const Color(0xFFD98A2B);

    if (isDark) {
      return _SlidePalette(
        background: const Color(0xFF0F1D3A),
        foreground: const Color(0xFFF5F7FA),
        muted: const Color(0xFFCBD5E1),
        accent: accent,
        border: const Color(0xFF263859),
      );
    }
    return _SlidePalette(
      background: const Color(0xFFF5F5F0),
      foreground: const Color(0xFF0F1D3A),
      muted: const Color(0xFF475569),
      accent: accent,
      border: const Color(0xFFD6D3CD),
    );
  }

  static Color? _parseHexColor(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim().replaceFirst('#', '');
    if (cleaned.length != 6) return null;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }
}
