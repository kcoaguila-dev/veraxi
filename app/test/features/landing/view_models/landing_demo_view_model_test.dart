import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/landing/view_models/landing_demo_view_model.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  LandingDemoState currentState() => container.read(landingDemoProvider);
  LandingDemoViewModel viewModel() =>
      container.read(landingDemoProvider.notifier);

  test('starts on the first question and the first phrase', () {
    expect(currentState().question, 0);
    expect(currentState().claim, 0);
  });

  test('selecting a question resets the selected phrase', () {
    viewModel().selectClaim(2);
    expect(currentState().claim, 2);

    viewModel().selectQuestion(1);

    expect(currentState().question, 1);
    expect(currentState().claim, 0);
  });

  test('ignores indexes that are out of range', () {
    viewModel().selectQuestion(kDemoQuestions.length);
    viewModel().selectQuestion(-1);
    viewModel().selectClaim(99);
    viewModel().selectClaim(-1);

    expect(currentState().question, 0);
    expect(currentState().claim, 0);
  });

  test('sample content only refers to claims that exist', () {
    for (final question in kDemoQuestions) {
      final claimCount = question.claims.length;

      for (final segment in question.segments) {
        final claim = segment.claim;
        if (claim != null) {
          expect(claim, lessThan(claimCount), reason: question.question);
        }
      }

      for (final source in question.sources) {
        for (final passage in source.passages) {
          for (final claim in passage.claims) {
            expect(claim, lessThan(claimCount), reason: question.question);
          }
        }
      }
    }
  });

  test('every claim in the sample answers is backed by a passage', () {
    for (final question in kDemoQuestions) {
      for (var claim = 0; claim < question.claims.length; claim++) {
        final backed = question.sources.any(
          (source) => source.passages.any((p) => p.claims.contains(claim)),
        );
        expect(backed, isTrue, reason: '${question.question} / claim $claim');
      }
    }
  });
}
