import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/tool_confirmation_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_confirmation_card.dart';

class _FakeConfirmationService extends ToolConfirmationService {
  _FakeConfirmationService() : super(_UnusedRepository());

  final List<bool> decisions = [];

  @override
  Future<Map<String, dynamic>> decide(
    ToolConfirmationRequest request, {
    required bool approve,
  }) async {
    decisions.add(approve);
    return {'status': approve ? 'executed' : 'rejected'};
  }
}

class _UnusedRepository extends Fake implements IChatRepository {}

void main() {
  testWidgets('approve calls the service and shows Executed',
      (WidgetTester tester) async {
    final fake = _FakeConfirmationService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          toolConfirmationServiceProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ToolConfirmationCard(
              request: ToolConfirmationRequest(
                toolName: 'github_create_issue',
                args: {'repo': 'o/r', 'title': 'Bug'},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.text('github_create_issue'), findsOneWidget);
    expect(find.textContaining('repo: o/r'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(fake.decisions, [true]);
    expect(find.text('Executed ✓'), findsOneWidget);
    // The card cannot be acted on twice.
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('reject calls the service and shows Rejected',
      (WidgetTester tester) async {
    final fake = _FakeConfirmationService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          toolConfirmationServiceProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ToolConfirmationCard(
              request: ToolConfirmationRequest(
                toolName: 'github_comment_pr',
                args: {'repo': 'o/r', 'pr_number': 3},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(fake.decisions, [false]);
    expect(find.text('Rejected'), findsOneWidget);
  });
}
