import 'dart:convert';

/// A structured table inside a single [SlideItem].
class SlideTable {
  final List<String> headers;
  final List<List<String>> rows;

  const SlideTable({
    required this.headers,
    required this.rows,
  });

  Map<String, dynamic> toJson() => {
        'headers': headers,
        'rows': rows,
      };
}

/// A single slide parsed from a `create_office_artifact` (`format: "pptx"`)
/// JSON envelope.
class SlideItem {
  final String title;
  final String? subtitle;
  final List<String> bullets;
  final SlideTable? table;
  final String? notes;

  /// Optional theme hint: `"dark"` or `"light"`.
  final String? theme;

  /// Optional hex accent color, e.g. `"#D98A2B"`.
  final String? accentColor;

  const SlideItem({
    required this.title,
    this.subtitle,
    this.bullets = const [],
    this.table,
    this.notes,
    this.theme,
    this.accentColor,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (bullets.isNotEmpty) 'bullets': bullets,
        if (table != null) 'table': table!.toJson(),
        if (notes != null) 'notes': notes,
        if (theme != null) 'theme': theme,
        if (accentColor != null) 'accent_color': accentColor,
      };
}

/// A parsed presentation deck from an `OfficeArtifactEnvelope` with a
/// `slides` array.
class SlideDeck {
  final String title;
  final List<SlideItem> slides;

  const SlideDeck({
    required this.title,
    required this.slides,
  });
}

/// Parses raw JSON [code] as a [SlideDeck], or returns `null` if [code] is
/// not a valid slides envelope (so plain JSON artifacts stay code listings).
SlideDeck? parseSlideDeckFromJson(String code) {
  final Object? decoded;
  try {
    decoded = jsonDecode(code);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final rawSlides = decoded['slides'];
  if (rawSlides is! List || rawSlides.isEmpty) return null;

  final slides = <SlideItem>[];
  for (final item in rawSlides) {
    if (item is! Map<String, dynamic>) continue;
    slides.add(_parseSlideItem(item));
  }
  if (slides.isEmpty) return null;

  final rawTitle = decoded['title'];
  final title = rawTitle is String && rawTitle.trim().isNotEmpty
      ? rawTitle.trim()
      : 'Presentation';
  return SlideDeck(title: title, slides: slides);
}

SlideItem _parseSlideItem(Map<String, dynamic> map) {
  final rawBullets = map['bullets'];
  final bullets = rawBullets is List
      ? rawBullets.map((e) => e.toString()).toList()
      : const <String>[];

  final table = _parseSlideTable(map['table']);
  final rawTitle = map['title'];
  final rawSubtitle = map['subtitle'];
  final rawNotes = map['notes'];
  final rawTheme = map['theme'];
  final rawAccent = map['accent_color'];

  return SlideItem(
    title: rawTitle is String ? rawTitle : '',
    subtitle:
        rawSubtitle is String && rawSubtitle.isNotEmpty ? rawSubtitle : null,
    bullets: bullets,
    table: table,
    notes: rawNotes is String && rawNotes.isNotEmpty ? rawNotes : null,
    theme: rawTheme is String && rawTheme.isNotEmpty ? rawTheme : null,
    accentColor: rawAccent is String && rawAccent.isNotEmpty ? rawAccent : null,
  );
}

SlideTable? _parseSlideTable(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  final rawHeaders = raw['headers'];
  final rawRows = raw['rows'];
  final headers = rawHeaders is List
      ? rawHeaders.map((e) => e.toString()).toList()
      : const <String>[];
  final rows = rawRows is List
      ? rawRows
          .whereType<List>()
          .map((row) => row.map((cell) => cell.toString()).toList())
          .toList()
      : const <List<String>>[];
  if (headers.isEmpty && rows.isEmpty) return null;
  return SlideTable(headers: headers, rows: rows);
}

/// Returns updated JSON with a new blank slide appended, preserving all
/// top-level envelope fields (`format`, `title`, etc.). Returns `null` if
/// [code] cannot be parsed as a slides envelope.
String? appendSlideToDeckJson(String code) {
  final Object? decoded;
  try {
    decoded = jsonDecode(code);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final rawSlides = decoded['slides'];
  if (rawSlides is! List) return null;

  final nextIndex = rawSlides.length + 1;
  final nextTheme = nextIndex.isOdd ? 'dark' : 'light';
  final updatedSlides = [
    ...rawSlides,
    {
      'title': 'Slide $nextIndex',
      'theme': nextTheme,
      'accent_color': '#D98A2B',
    },
  ];
  final updated = Map<String, dynamic>.from(decoded);
  updated['slides'] = updatedSlides;
  return const JsonEncoder.withIndent('  ').convert(updated);
}
