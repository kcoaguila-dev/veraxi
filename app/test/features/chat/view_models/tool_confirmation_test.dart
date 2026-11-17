import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/tool_confirmation_view_model.dart';

void main() {
  group('extractToolConfirmation', () {
    test('parses the JSON form', () {
      const content =
          'The tool needs approval: {"tool_confirmation_required": {"tool_name": "github_create_issue", "args": {"repo": "o/r", "title": "Bug"}, "message": "needs approval"}}';
      final request = extractToolConfirmation(content);
      expect(request, isNotNull);
      expect(request!.toolName, 'github_create_issue');
      expect(request.args['repo'], 'o/r');
      expect(request.args['title'], 'Bug');
    });

    test('parses the Python-repr form from telemetry context', () {
      const content =
          "[EXTERNAL TELEMETRY & ACTIONS]:\n[Tool Confirmation]:\n{'tool_confirmation_required': {'tool_name': 'api__widgets__createWidget', 'args': {'name': 'w'}, 'message': 'needs approval'}}";
      final request = extractToolConfirmation(content);
      expect(request, isNotNull);
      expect(request!.toolName, 'api__widgets__createWidget');
      expect(request.args['name'], 'w');
    });

    test('returns null without a confirmation payload', () {
      expect(extractToolConfirmation('Just a normal answer.'), isNull);
      expect(extractToolConfirmation('{"unrelated": true}'), isNull);
    });

    test('returns null when tool_name is missing', () {
      const content = '{"tool_confirmation_required": {"args": {}}}';
      expect(extractToolConfirmation(content), isNull);
    });
  });
}
