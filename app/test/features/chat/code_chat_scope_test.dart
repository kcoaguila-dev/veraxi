import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/data/code_file_repository.dart';
import 'package:veraxi_app/features/chat/view_models/code_chat_view_model.dart';

void main() {
  group('buildCodeScope', () {
    test('stamps the Phase 1 top-level chat request fields', () {
      final scope = buildCodeScope(
        repoKey: 'veraxi/backend',
        branch: 'main',
        thinkingLevel: 'High',
        executionMode: CodeExecutionMode.plan,
        autonomyMode: 'auto_read_test',
        sources: const CodeSelectedSources(
          repoKeys: {'veraxi/backend', 'veraxi/app'},
          docIds: {'doc-1'},
        ),
      );

      expect(scope['workspace_mode'], 'code');
      expect(scope['repo_key'], 'veraxi/backend');
      expect(scope['branch'], 'main');
      expect(scope['thinking_level'], 'high');
      expect(scope['execution_mode'], 'plan');
      expect(scope['autonomy_mode'], 'auto_read_test');
      final sourceScope = scope['source_scope'] as Map<String, dynamic>;
      expect(sourceScope['repo_keys'],
          containsAll(<String>['veraxi/backend', 'veraxi/app']));
      expect(sourceScope['doc_ids'], ['doc-1']);
      // Mirrored so the backend Qdrant scope filter applies.
      expect(sourceScope['source_ids'], ['doc-1']);
    });

    test('omits repo_key and branch when unknown', () {
      final scope = buildCodeScope(
        repoKey: null,
        branch: '',
        thinkingLevel: 'Medium',
        executionMode: CodeExecutionMode.act,
        autonomyMode: 'ask_all',
        sources: const CodeSelectedSources(),
      );

      expect(scope.containsKey('repo_key'), isFalse);
      expect(scope.containsKey('branch'), isFalse);
      expect(scope['execution_mode'], 'act');
    });
  });

  group('codeAutonomyLabel', () {
    test('maps backend tiers to composer labels', () {
      expect(codeAutonomyLabel('ask_all'), 'Request Review');
      expect(codeAutonomyLabel('auto_read_test'), 'Default');
      expect(codeAutonomyLabel('auto_workspace_writes'), 'Auto');
      expect(codeAutonomyLabel('autonomous'), 'Turbo');
    });
  });

  group('CodeFileListEntry', () {
    test('parses a /api/v1/code/files row and derives the name', () {
      final entry = CodeFileListEntry.fromJson(const {
        'path': 'backend/retrieval/merge_rank.py',
        'language': 'python',
        'repo_key': 'veraxi/backend',
      });
      expect(entry.name, 'merge_rank.py');
      expect(entry.language, 'python');
      expect(entry.repoKey, 'veraxi/backend');
    });
  });
}
