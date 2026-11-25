import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/chat/views/widgets/selection_edge_auto_scroll.dart';

void main() {
  testWidgets(
      'SelectionEdgeAutoScroll scrolls down when dragging mouse into bottom edge zone',
      (tester) async {
    late ScrollController capturedController;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: SelectionEdgeAutoScroll(
              builder: (context, controller) {
                capturedController = controller;
                return SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: List.generate(
                      40,
                      (i) => SizedBox(
                        height: 30,
                        child: Text('Line $i'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(capturedController.offset, 0.0);

    final gesture = await tester.startGesture(
      const Offset(100, 100),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(const Offset(100, 290));
    await tester.pump(const Duration(milliseconds: 120));

    expect(capturedController.offset, greaterThan(0.0));

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
