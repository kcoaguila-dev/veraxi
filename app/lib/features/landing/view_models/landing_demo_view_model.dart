import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/landing/data/demo_samples.dart';

// Views read the sample types through this file, because views may not import
// the data layer directly.
export 'package:veraxi_app/features/landing/data/demo_samples.dart';

/// Which sample question and which highlighted phrase are selected.
class LandingDemoState {
  final int question;
  final int claim;

  const LandingDemoState({this.question = 0, this.claim = 0});

  DemoQuestion get activeQuestion => kDemoQuestions[question];
}

class LandingDemoViewModel extends StateNotifier<LandingDemoState> {
  LandingDemoViewModel() : super(const LandingDemoState());

  /// Switches to another sample question and selects its first phrase.
  void selectQuestion(int index) {
    if (index < 0 || index >= kDemoQuestions.length) return;
    state = LandingDemoState(question: index);
  }

  /// Selects a highlighted phrase in the current answer.
  void selectClaim(int index) {
    final claimCount = state.activeQuestion.claims.length;
    if (index < 0 || index >= claimCount) return;
    state = LandingDemoState(question: state.question, claim: index);
  }
}

final landingDemoProvider =
    StateNotifierProvider<LandingDemoViewModel, LandingDemoState>((ref) {
  return LandingDemoViewModel();
});
