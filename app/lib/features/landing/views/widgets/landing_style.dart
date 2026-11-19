import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Colors for the landing page. The page has its own light palette and does
/// not follow the app's light/dark toggle.
class LandingColors {
  const LandingColors._();

  static const Color paper = Color(0xFFEDF0EE);
  static const Color panel = Color(0xFFFAFBFA);
  static const Color line = Color(0xFFC3CBC6);
  static const Color ink = Color(0xFF16191C);
  static const Color grey = Color(0xFF55606A);
  static const Color cobalt = Color(0xFF2436C9);
  static const Color cobaltDark = Color(0xFF1B2A9E);
  static const Color highlight = Color(0xFFF4DD6B);
  static const Color code = Color(0xFF0E1550);
  static const Color nodeLine = Color(0xFFB9C3E6);
  static const Color onCobalt = Color(0xFFF4F6F4);
  static const Color onCobaltSoft = Color(0xFFD9DEFF);
}

/// Type for the landing page: a grotesk for headings and interface text,
/// a serif for answers and reading, a mono face for commands only.
class LandingType {
  const LandingType._();

  static TextStyle sans({
    double size = 16,
    FontWeight weight = FontWeight.w500,
    Color color = LandingColors.ink,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.getFont(
      'Schibsted Grotesk',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextStyle serif({
    double size = 17,
    FontWeight weight = FontWeight.w400,
    Color color = LandingColors.ink,
    double? height,
  }) {
    return GoogleFonts.getFont(
      'Literata',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  static TextStyle mono({
    double size = 15,
    Color color = LandingColors.ink,
    double? height,
  }) {
    return GoogleFonts.getFont(
      'IBM Plex Mono',
      fontSize: size,
      color: color,
      height: height,
    );
  }
}

class LandingLayout {
  const LandingLayout._();

  static const double maxWidth = 1120;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 900;

  static double gutter(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 20 : 32;

  /// Vertical space between sections, between 56 and 112 logical pixels.
  static double sectionGap(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.08).clamp(56.0, 112.0).toDouble();
}

Future<void> openLandingUrl(String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  }
}

/// Centers content in a column of at most 1120 pixels with side gutters.
class LandingColumn extends StatelessWidget {
  final Widget child;
  final double top;
  final double bottom;

  const LandingColumn({
    super.key,
    required this.child,
    this.top = 0,
    this.bottom = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: LandingLayout.maxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            LandingLayout.gutter(context),
            top,
            LandingLayout.gutter(context),
            bottom,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Side-by-side columns on wide screens, stacked on narrow ones.
class LandingColumns extends StatelessWidget {
  final List<Widget> children;
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;

  const LandingColumns({
    super.key,
    required this.children,
    this.gap = 40,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    if (LandingLayout.isWide(context)) {
      final row = <Widget>[];
      for (var i = 0; i < children.length; i++) {
        if (i > 0) row.add(SizedBox(width: gap));
        row.add(Expanded(child: children[i]));
      }
      return Row(crossAxisAlignment: crossAxisAlignment, children: row);
    }
    final column = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) column.add(SizedBox(height: gap));
      column.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: column,
    );
  }
}

class LandingHeading extends StatelessWidget {
  final String text;
  final Color color;

  const LandingHeading(this.text, {super.key, this.color = LandingColors.ink});

  @override
  Widget build(BuildContext context) {
    final size =
        (MediaQuery.sizeOf(context).width * 0.044).clamp(32.0, 52.0).toDouble();
    return Semantics(
      header: true,
      child: Text(
        text,
        style: LandingType.sans(
          size: size,
          weight: FontWeight.w800,
          color: color,
          height: 1.05,
          letterSpacing: -size * 0.035,
        ),
      ),
    );
  }
}

class LandingBody extends StatelessWidget {
  final String text;
  final double size;
  final Color color;
  final double maxWidth;

  const LandingBody(
    this.text, {
    super.key,
    this.size = 17,
    this.color = LandingColors.ink,
    this.maxWidth = 620,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        text,
        style: LandingType.serif(size: size, color: color, height: 1.65),
      ),
    );
  }
}

class LandingButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  /// Use on the cobalt band, where the default cobalt button would vanish.
  final bool light;

  const LandingButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: light ? LandingColors.onCobalt : LandingColors.cobalt,
        foregroundColor: light ? LandingColors.cobaltDark : Colors.white,
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 26),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: LandingType.sans(size: 17, weight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class LandingTextLink extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final Color color;

  const LandingTextLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = LandingColors.ink,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: LandingType.sans(size: 17, weight: FontWeight.w600)
            .copyWith(decoration: TextDecoration.underline),
      ),
      child: Text(label),
    );
  }
}
