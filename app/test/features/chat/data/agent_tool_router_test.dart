import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/data/agent_tool_router.dart';

void main() {
  group('AgentToolRouter', () {
    late AgentToolRouter router;

    setUp(() {
      router = AgentToolRouter(navigatorKey: GlobalKey<NavigatorState>());
    });

    test('tools() returns expected list of schemas', () {
      final tools = agentToolsForPlatform();
      // On non-android, we expect 3 tools
      expect(tools.length, 3);

      final names = tools.map((t) => t['function']['name']).toList();
      expect(names, containsAll(['read_file', 'write_file', 'list_files']));
    });

    test('dispatch handles missing tool gracefully', () async {
      final result = await router.dispatch('non_existent_tool', {});
      expect(result.summary, contains('Unknown tool'));
    });
  });
}
