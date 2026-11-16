import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('artifactWorkKey', () {
    test('builds thread:message:block coordinates', () {
      expect(
        artifactWorkKey(threadId: 't1', messageIndex: 3, artifactIndex: 1),
        't1:3:1',
      );
      expect(
        artifactWorkKey(threadId: null, messageIndex: 0, artifactIndex: 0),
        'local:0:0',
      );
    });

    test('null without a message index', () {
      expect(
        artifactWorkKey(threadId: 't1', messageIndex: null, artifactIndex: 0),
        isNull,
      );
    });
  });

  group('ArtifactWorkStore', () {
    test('save/load round-trips versions and the published link', () async {
      final store = ArtifactWorkStore();
      const state = ArtifactWorkState(
        versions: ['print("v1")', 'print("v2")'],
        versionIndex: 1,
        originalCode: 'print("v1")',
        publishedId: 'abc',
        publishedUrl: 'https://veraxi.me/a/abc',
        publishedCode: 'print("v2")',
      );

      await store.save('t1:0:0', state);
      final loaded = await store.load('t1:0:0');

      expect(loaded, isNotNull);
      expect(loaded!.versions, ['print("v1")', 'print("v2")']);
      expect(loaded.versionIndex, 1);
      expect(loaded.originalCode, 'print("v1")');
      expect(loaded.publishedId, 'abc');
      expect(loaded.publishedUrl, 'https://veraxi.me/a/abc');
      expect(loaded.publishedCode, 'print("v2")');
      expect(loaded.hasUserWork, isTrue);
    });

    test('a missing key loads as null', () async {
      expect(await ArtifactWorkStore().load('nope:0:0'), isNull);
    });

    test('a single untouched version is not user work', () {
      const state = ArtifactWorkState(
        versions: ['print("v1")'],
        versionIndex: 0,
        originalCode: 'print("v1")',
      );
      expect(state.hasUserWork, isFalse);
    });

    test('corrupt stored JSON loads as null instead of throwing', () async {
      SharedPreferences.setMockInitialValues({
        'artifact_work_states_v1': '{not json',
      });
      expect(await ArtifactWorkStore().load('t1:0:0'), isNull);
    });

    test('entries are capped, evicting the oldest first', () async {
      final store = ArtifactWorkStore();
      for (var i = 0; i < 105; i++) {
        await store.save(
          't:$i:0',
          ArtifactWorkState(
            versions: ['v$i'],
            versionIndex: 0,
            originalCode: 'v$i',
          ),
        );
      }
      expect(await store.load('t:0:0'), isNull);
      expect(await store.load('t:4:0'), isNull);
      expect(await store.load('t:5:0'), isNotNull);
      expect(await store.load('t:104:0'), isNotNull);
    });
  });
}
