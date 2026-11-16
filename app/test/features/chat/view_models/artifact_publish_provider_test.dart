import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/artifact_publish_repository.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_publish_provider.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

class MockArtifactPublishRepository extends Mock
    implements ArtifactPublishRepository {}

void main() {
  const artifact = CodeArtifact(
    title: 'Hello world',
    fileName: 'hello_world.py',
    language: 'python',
    code: 'print("v1")',
  );

  late MockArtifactPublishRepository repository;
  late ArtifactPublishController controller;

  setUp(() {
    repository = MockArtifactPublishRepository();
    controller = ArtifactPublishController(repository);
  });

  tearDown(() => controller.dispose());

  group('ArtifactPublishController', () {
    test('publish stores the id, url, and published code', () async {
      when(() => repository.publish(
            title: any(named: 'title'),
            fileName: any(named: 'fileName'),
            language: any(named: 'language'),
            code: any(named: 'code'),
            kind: any(named: 'kind'),
            existingId: any(named: 'existingId'),
          )).thenAnswer(
        (_) async => const PublishedArtifact(id: 'abc', url: 'https://x/a/abc'),
      );

      await controller.publish(artifact, 'print("v1")');

      expect(controller.state.publishedId, 'abc');
      expect(controller.state.publishedUrl, 'https://x/a/abc');
      expect(controller.state.publishedCode, 'print("v1")');
      expect(controller.state.isPublishing, isFalse);
      expect(controller.state.error, isNull);
      expect(controller.state.isStale('print("v1")'), isFalse);
      expect(controller.state.isStale('print("v2")'), isTrue);
    });

    test('republishing passes the existing id so the URL is stable', () async {
      String? capturedExistingId;
      when(() => repository.publish(
            title: any(named: 'title'),
            fileName: any(named: 'fileName'),
            language: any(named: 'language'),
            code: any(named: 'code'),
            kind: any(named: 'kind'),
            existingId: any(named: 'existingId'),
          )).thenAnswer((invocation) async {
        capturedExistingId = invocation.namedArguments[#existingId] as String?;
        return const PublishedArtifact(id: 'abc', url: 'https://x/a/abc');
      });

      await controller.publish(artifact, 'print("v1")');
      await controller.publish(artifact, 'print("v2")');

      expect(capturedExistingId, 'abc');
      expect(controller.state.publishedCode, 'print("v2")');
    });

    test('a 401 becomes a sign-in message, and no link is kept', () async {
      when(() => repository.publish(
            title: any(named: 'title'),
            fileName: any(named: 'fileName'),
            language: any(named: 'language'),
            code: any(named: 'code'),
            kind: any(named: 'kind'),
            existingId: any(named: 'existingId'),
          )).thenThrow(Exception('Server error: 401'));

      await controller.publish(artifact, 'print("v1")');

      expect(controller.state.error, 'Sign in to publish artifacts.');
      expect(controller.state.publishedUrl, isNull);
      expect(controller.state.isPublishing, isFalse);
    });

    test('unpublish calls the backend and forgets the link', () async {
      when(() => repository.publish(
            title: any(named: 'title'),
            fileName: any(named: 'fileName'),
            language: any(named: 'language'),
            code: any(named: 'code'),
            kind: any(named: 'kind'),
            existingId: any(named: 'existingId'),
          )).thenAnswer(
        (_) async => const PublishedArtifact(id: 'abc', url: 'https://x/a/abc'),
      );
      when(() => repository.unpublish('abc')).thenAnswer((_) async {});

      await controller.publish(artifact, 'print("v1")');
      await controller.unpublish();

      verify(() => repository.unpublish('abc')).called(1);
      expect(controller.state.publishedUrl, isNull);
      expect(controller.state.publishedId, isNull);
    });
  });
}
