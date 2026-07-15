# 3. Use Flutter for Frontend Interface

Date: 2026-07-15

## Status

Accepted

## Context

The Veraxi system requires a modern, high-performance user interface. The UI must eventually support both web deployments and native desktop/mobile experiences without requiring the team to maintain three separate codebases (e.g., React for Web, Swift for iOS, Kotlin for Android).

## Decision

We will use **Flutter (Dart)** as the sole frontend framework. State management will be handled by **Riverpod**, and the architecture will strictly follow a feature-first folder structure (`lib/features/<feature_name>/`).

## Consequences

**Positive:**
- A single codebase compiles to Web, iOS, Android, macOS, Windows, and Linux.
- Extremely high rendering performance due to the Impeller/Skia graphics engine.
- Strict typing with Dart's Null Safety prevents runtime crashes.

**Negative:**
- Flutter web bundles can be larger than raw HTML/JS, leading to slightly longer initial load times on the web.
- The Dart ecosystem for highly specific data visualization libraries is smaller than the JavaScript/React ecosystem.
