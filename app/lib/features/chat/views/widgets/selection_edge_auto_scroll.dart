import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Wraps a scrollable built with [builder] inside a [SelectionArea] and
/// auto-scrolls when the user drags near or past the top/bottom edge of
/// the viewport during mouse text selection.
///
/// Flutter's built-in [EdgeDraggingAutoScroller] only triggers when the
/// pointer moves strictly outside the scrollable bounds, which cannot
/// happen when a pane extends to the bottom edge of the browser window.
class SelectionEdgeAutoScroll extends StatefulWidget {
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  /// Optional externally-owned [ScrollController]. When omitted, this widget
  /// creates and disposes its own controller.
  final ScrollController? controller;

  /// Extra bottom inset (e.g. height of a floating composer) before the
  /// downward auto-scroll zone starts.
  final double bottomEdgeInset;

  const SelectionEdgeAutoScroll({
    super.key,
    required this.builder,
    this.controller,
    this.bottomEdgeInset = 0.0,
  });

  @override
  State<SelectionEdgeAutoScroll> createState() =>
      _SelectionEdgeAutoScrollState();
}

class _SelectionEdgeAutoScrollState extends State<SelectionEdgeAutoScroll> {
  static const double _edgeZonePx = 44.0;
  static const double _scrollbarGutterPx = 16.0;
  static const double _minStepPx = 4.0;
  static const double _maxStepPx = 18.0;

  late final ScrollController _ownedController = ScrollController();
  ScrollController get _controller => widget.controller ?? _ownedController;
  Timer? _scrollTimer;
  bool _isMouseDragging = false;
  Offset? _lastGlobalPosition;

  @override
  void dispose() {
    _stopTimer();
    _ownedController.dispose();
    super.dispose();
  }

  void _stopTimer() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }

  void _stopDragging() {
    _isMouseDragging = false;
    _lastGlobalPosition = null;
    _stopTimer();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      final local = box.globalToLocal(event.position);
      if (local.dx > box.size.width - _scrollbarGutterPx) {
        return;
      }
    }
    _isMouseDragging = true;
    _lastGlobalPosition = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isMouseDragging) return;
    if ((event.buttons & kPrimaryMouseButton) == 0) {
      _stopDragging();
      return;
    }
    _lastGlobalPosition = event.position;
    _updateAutoScroll();
  }

  double _computeScrollDelta() {
    if (_lastGlobalPosition == null) return 0.0;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0.0;

    final localY = box.globalToLocal(_lastGlobalPosition!).dy;
    final height = box.size.height;
    final bottomTriggerY = height - widget.bottomEdgeInset - _edgeZonePx;
    if (bottomTriggerY <= _edgeZonePx) return 0.0;

    if (localY >= bottomTriggerY) {
      final depth = (localY - bottomTriggerY).clamp(0.0, _edgeZonePx * 2) /
          (_edgeZonePx * 2);
      return _minStepPx + depth * (_maxStepPx - _minStepPx);
    }
    if (localY <= _edgeZonePx) {
      final depth = (_edgeZonePx - localY).clamp(0.0, _edgeZonePx * 2) /
          (_edgeZonePx * 2);
      return -(_minStepPx + depth * (_maxStepPx - _minStepPx));
    }
    return 0.0;
  }

  void _updateAutoScroll() {
    if (_computeScrollDelta() == 0.0) {
      _stopTimer();
      return;
    }
    _scrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickScroll(),
    );
  }

  void _tickScroll() {
    if (!mounted || !_isMouseDragging || !_controller.hasClients) {
      _stopTimer();
      return;
    }
    final delta = _computeScrollDelta();
    if (delta == 0.0) {
      _stopTimer();
      return;
    }
    final pos = _controller.position;
    final target =
        (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (target != pos.pixels) {
      _controller.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _stopDragging(),
      onPointerCancel: (_) => _stopDragging(),
      child: SelectionArea(
        child: widget.builder(context, _controller),
      ),
    );
  }
}
