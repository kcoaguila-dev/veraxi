<!--
Read CONTRIBUTING.md before opening a PR. Solve one underlying problem per PR —
cleanup, refactors, and second fixes go in their own PRs.
Use a conventional-commit title in plain language, such as
"fix(retrieval): BM25 sparse search no longer returns 0 hits when scoped".
-->

## Problem

<!-- Explain the problem in a sentence or two. Include expected vs actual
behaviour, and reproduction steps or environment where relevant. If this fixes
an open issue, link it here. -->

## Change

<!-- Explain how this change fixes the problem. If it spans backend, client,
contracts, or docs, explain why each part is needed for the same fix. -->

## Scope

<!-- Type of change:
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update

Anything deliberately left out of this PR, and why. -->

## Verification

<!-- Describe the focused tests or manual checks you ran and the observed
results for the changed behaviour. "Tests pass" alone is insufficient — name
the commands and what you saw. State anything you could not check.

For UI changes, include clear before/after screenshots. Upload evidence to the
PR; do not commit PR-only assets. -->

## Architect's Checklist

Before requesting a review from `@kcoaguila-dev`, ensure you have completed the following:

- [ ] My code respects the architectural boundaries outlined in `AGENTS.md` and `CONTRIBUTING.md`.
- [ ] I have run `make setup` and `make test` locally, and all tests pass.
- [ ] I did not use `--no-verify` to bypass the `pre-commit` security hooks (Gitleaks).
- [ ] I have added tests that prove my fix is effective or that my feature works.
- [ ] I have updated the documentation if necessary.

<!-- If an AI agent did the work, end with the model and harness that did it. -->
