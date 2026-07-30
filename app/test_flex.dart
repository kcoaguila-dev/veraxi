import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Test RenderFlex', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Container(
                width: 200,
                child: Column(
                  children: [
                    Expanded(child: Container(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Container), findsWidgets);
  });
}
