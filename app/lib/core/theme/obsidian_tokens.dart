import 'package:material_ui/material_ui.dart';

/// Obsidian design tokens for the Code Mode workbench.
///
/// Exact values from the visual contract in
/// `docs/design/veraxi_code_workbench.svg` and the Code Mode plan
/// (P4/P5 sections). These are fixed dark-surface tokens for the Code
/// shell — they do not follow the app light/dark theme.
class ObsidianTokens {
  const ObsidianTokens._();

  /// Outer shell / left rail background (`#0D0E11`).
  static const Color shell = Color(0xFF0D0E11);

  /// Recessed center-stage canvas (`#060709`).
  static const Color recessedCanvas = Color(0xFF060709);

  /// Raised card surface (`#111317`).
  static const Color card = Color(0xFF111317);

  /// Floating composer surface (`#13151A`).
  static const Color composer = Color(0xFF13151A);

  /// User message bubble surface (`#181A20`).
  static const Color bubble = Color(0xFF181A20);

  /// Hairline divider / border (`#1E2026`).
  static const Color hairline = Color(0xFF1E2026);

  /// Stronger border for emphasized outlines (`#282B36`).
  static const Color borderStrong = Color(0xFF282B36);

  /// Composer outline (`#252833`).
  static const Color composerBorder = Color(0xFF252833);

  /// Welded tray docked above the composer (`#0C0D10`).
  static const Color weldedTray = Color(0xFF0C0D10);

  /// Border around the recessed canvas card (`#1C1E24`).
  static const Color canvasBorder = Color(0xFF1C1E24);

  /// Diff added-line background (`#0F291A`).
  static const Color diffAddBg = Color(0xFF0F291A);

  /// Diff removed-line background (`#2A1215`).
  static const Color diffRemoveBg = Color(0xFF2A1215);

  /// Inline code span background (`#16181D`).
  static const Color codeSpanBg = Color(0xFF16181D);

  /// Inline code span text (`#E4E4E7`).
  static const Color codeSpanText = Color(0xFFE4E4E7);
}
