import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_incoming_provider.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';

ChatMessage _assistant(String content, {bool streaming = false}) =>
    ChatMessage(role: 'assistant', content: content, isStreaming: streaming);

ChatMessage _user(String content) =>
    ChatMessage(role: 'user', content: content);

const _source = '''
Here's `hello_world.py`:

```python
print("v1")
```
''';

const _reply = '''
Fixed `hello_world.py`:

```python
print("v2")
```
''';

void main() {
  group('quickActionReplyArtifacts', () {
    test('null while no reply has arrived', () {
      final state = ChatState(threadId: 't1', messages: [
        _assistant(_source),
        _user('Fix the bugs...'),
      ]);
      expect(
        quickActionReplyArtifacts(state, threadId: 't1', afterMessageIndex: 0),
        isNull,
      );
    });

    test('null while the reply is still streaming', () {
      final state = ChatState(threadId: 't1', messages: [
        _assistant(_source),
        _user('Fix the bugs...'),
        _assistant(_reply, streaming: true),
      ]);
      expect(
        quickActionReplyArtifacts(state, threadId: 't1', afterMessageIndex: 0),
        isNull,
      );
    });

    test('the completed reply\'s artifacts are returned', () {
      final state = ChatState(threadId: 't1', messages: [
        _assistant(_source),
        _user('Fix the bugs...'),
        _assistant(_reply),
      ]);
      final artifacts = quickActionReplyArtifacts(
        state,
        threadId: 't1',
        afterMessageIndex: 0,
      );
      expect(artifacts, hasLength(1));
      expect(artifacts!.single.code, 'print("v2")');
      expect(artifacts.single.fileName, 'hello_world.py');
    });

    test('a reply without code returns an empty list, not null', () {
      final state = ChatState(threadId: 't1', messages: [
        _assistant(_source),
        _user('Review this'),
        _assistant('Looks fine overall.'),
      ]);
      expect(
        quickActionReplyArtifacts(state, threadId: 't1', afterMessageIndex: 0),
        isEmpty,
      );
    });

    test('only the FIRST assistant message counts as the reply', () {
      final state = ChatState(threadId: 't1', messages: [
        _assistant(_source),
        _user('Fix the bugs...'),
        _assistant(_reply),
        _user('Something else'),
        _assistant('```python\nprint("unrelated")\n```'),
      ]);
      final artifacts = quickActionReplyArtifacts(
        state,
        threadId: 't1',
        afterMessageIndex: 0,
      );
      expect(artifacts!.single.code, 'print("v2")');
    });

    test('a different thread yields null', () {
      final state = ChatState(threadId: 't2', messages: [
        _assistant(_source),
        _user('Fix the bugs...'),
        _assistant(_reply),
      ]);
      expect(
        quickActionReplyArtifacts(state, threadId: 't1', afterMessageIndex: 0),
        isNull,
      );
    });
  });
}
