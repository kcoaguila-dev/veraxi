import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/widgets/veraxi_switch.dart';

void main() {
  testWidgets(
      'VeraxiSwitch toggles on tap and keyboard activation with Semantics',
      (tester) async {
    bool current = false;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return VeraxiSwitch(
                value: current,
                focusNode: focusNode,
                semanticLabel: 'Include reachability',
                onChanged: (next) => setState(() => current = next),
              );
            },
          ),
        ),
      ),
    );

    final semanticsFinder = find.bySemanticsLabel('Include reachability');
    expect(semanticsFinder, findsOneWidget);
    expect(tester.getSemantics(semanticsFinder).flagsCollection.isToggled,
        ui.Tristate.isFalse);

    await tester.tap(find.byType(VeraxiSwitch));
    await tester.pumpAndSettle();
    expect(current, isTrue);
    expect(tester.getSemantics(semanticsFinder).flagsCollection.isToggled,
        ui.Tristate.isTrue);

    // Keyboard activation via Space toggles back to false.
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(current, isFalse);
  });
}
