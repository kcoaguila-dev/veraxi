"""Centralized lexical and stop word utilities for multilingual grounding, entity filtering, and RAG."""

import importlib
import logging
import re
from functools import lru_cache

logger = logging.getLogger(__name__)

# Precompiled regex for CJK unicode ranges (Chinese, Japanese, Korean)
_CJK_RE = re.compile(r"([\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af])")

# Precompiled regex for Cyrillic
_CYRILLIC_RE = re.compile(r"[\u0400-\u04ff]")

# Multilingual negation vocabulary across supported languages.
# Protected forensic keep-list: these words must NEVER be stripped as "meaningless stop words"
# during factual grounding polarity verification.
MULTILINGUAL_NEGATIONS: frozenset[str] = frozenset({
    # English
    "not", "never", "no", "without", "cannot", "none", "neither", "nor", "n't",
    # German
    "nicht", "nie", "niemals", "kein", "keine", "keinen", "keinem", "keines", "keiner", "ohne", "weder",
    # French
    "pas", "jamais", "aucun", "aucune", "sans", "point", "guère", "rien", "ne",
    # Spanish
    "no", "nunca", "jamás", "sin", "ninguno", "ninguna", "nada", "tampoco", "ni",
    # Portuguese
    "não", "nao", "nunca", "jamais", "sem", "nenhum", "nenhuma", "nada", "tampouco",
    # Italian
    "non", "mai", "senza", "nessuno", "nessuna", "niente", "neanche", "nemmeno",
    # Dutch
    "niet", "nooit", "geen", "zonder", "noch",
    # Russian
    "не", "нет", "никогда", "без", "никак", "ни",
    # CJK (Chinese / Japanese / Korean negation morphemes)
    "不", "没", "没有", "未", "无", "非", "ない", "ず", "ぬ", "ません", "안", "못", "없",
})

# Multilingual directional, temporal, and quantitative comparators.
# Protected forensic keep-list: these words determine numerical & legal bounds
# and must NEVER be stripped as meaningless stop words.
FORENSIC_COMPARATORS: frozenset[str] = frozenset({
    # English
    "under", "over", "less", "more", "most", "least", "above", "below",
    "before", "after", "between", "exceed", "exceeds", "exceeded",
    "minimum", "maximum", "only", "must",
    # German
    "unter", "über", "mehr", "weniger", "vor", "nach", "zwischen", "mindestens", "höchstens", "nur", "muss", "müssen",
    # French
    "sous", "plus", "moins", "avant", "après", "entre", "seulement", "doit",
    # Spanish
    "bajo", "sobre", "más", "menos", "antes", "después", "entre", "solo", "solamente", "debe",
    # Italian
    "sotto", "sopra", "più", "meno", "prima", "dopo", "tra", "fra", "solo", "deve",
    # Dutch
    "onder", "boven", "meer", "minder", "tussen", "alleen", "moet",
    # Russian
    "под", "над", "более", "менее", "больше", "меньше", "после", "между", "только", "должен",
    # Written numbers (frequently used in financial covenants)
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "zero", "first", "second", "third",
})

# Directed antonym / contradiction pairs for directional comparators
COMPARATOR_OPPOSITES: dict[str, frozenset[str]] = {
    # English
    "under": frozenset({"over", "above", "more", "exceed", "exceeds", "exceeded"}),
    "below": frozenset({"over", "above", "more", "exceed", "exceeds", "exceeded"}),
    "less": frozenset({"over", "above", "more", "exceed", "exceeds", "exceeded"}),
    "over": frozenset({"under", "below", "less"}),
    "above": frozenset({"under", "below", "less"}),
    "more": frozenset({"under", "below", "less"}),
    "before": frozenset({"after"}),
    "after": frozenset({"before"}),
    # German
    "unter": frozenset({"über", "mehr"}),
    "weniger": frozenset({"über", "mehr"}),
    "über": frozenset({"unter", "weniger"}),
    "mehr": frozenset({"unter", "weniger"}),
    "vor": frozenset({"nach"}),
    "nach": frozenset({"vor"}),
    # French
    "sous": frozenset({"plus"}),
    "moins": frozenset({"plus"}),
    "plus": frozenset({"sous", "moins"}),
    "avant": frozenset({"après"}),
    "après": frozenset({"avant"}),
    # Spanish
    "bajo": frozenset({"sobre", "más"}),
    "menos": frozenset({"sobre", "más"}),
    "sobre": frozenset({"bajo", "menos"}),
    "más": frozenset({"bajo", "menos"}),
    "antes": frozenset({"después"}),
    "después": frozenset({"antes"}),
}

# Language-specific marker keywords for heuristic language identification
_LANG_MARKERS: dict[str, tuple[str, ...]] = {
    "de": ("der", "die", "das", "und", "ist", "in", "den", "von", "zu", "mit", "sich", "auf"),
    "fr": ("le", "la", "les", "et", "dans", "pour", "des", "une", "est", "qui", "sur"),
    "es": ("el", "la", "los", "las", "en", "por", "para", "con", "del", "una", "que"),
    "pt": ("os", "as", "em", "para", "com", "uma", "do", "da", "que", "este"),
    "it": ("il", "lo", "gli", "nel", "della", "delle", "con", "per", "che", "sono"),
    "nl": ("het", "een", "van", "naar", "voor", "zijn", "op", "dat", "maar"),
    "ru": ("в", "и", "на", "с", "по", "для", "что", "это", "как", "из"),
}


def pretokenize_cjk(text: str) -> str:
    """Pad CJK characters with whitespace for consistent word-boundary tokenization."""
    if not text:
        return ""
    return _CJK_RE.sub(r" \1 ", text)


def detect_language(text: str) -> str:
    """Fast, $0 heuristic language detector for stop word selection."""
    if not text or not text.strip():
        return "en"

    if _CJK_RE.search(text):
        if re.search(r"[\u3040-\u30ff]", text):
            return "ja"
        if re.search(r"[\uac00-\ud7af]", text):
            return "ko"
        return "zh"

    if _CYRILLIC_RE.search(text):
        return "ru"

    lower_tokens = set(re.findall(r"\b[a-zà-ÿäöüß]+\b", text.lower()))
    if not lower_tokens:
        return "en"

    best_lang, best_overlap = "en", 0
    for lang, markers in _LANG_MARKERS.items():
        overlap = sum(1 for m in markers if m in lower_tokens)
        if overlap > best_overlap:
            best_overlap, best_lang = overlap, lang

    return best_lang if best_overlap >= 2 else "en"



@lru_cache(maxsize=32)
def _load_spacy_lang_stopwords(lang_code: str) -> frozenset[str]:
    """Dynamically load built-in spaCy stop words for a given language code without downloading model weights."""
    try:
        mod = importlib.import_module(f"spacy.lang.{lang_code}.stop_words")
        words = getattr(mod, "STOP_WORDS", None)
        if words:
            return frozenset(words)
    except Exception as exc:
        logger.debug(f"Could not load spaCy stop words for '{lang_code}': {exc}")

    # Fallback minimal English stop word list
    return frozenset({
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "both", "but", "by", "can", "could",
        "did", "do", "does", "doing", "during", "each", "few", "for", "from", "further",
        "had", "has", "have", "having", "he", "her", "here", "hers", "him", "his", "how",
        "i", "if", "in", "into", "is", "it", "its", "me", "more", "most", "my", "of", "off",
        "on", "once", "only", "or", "other", "our", "out", "own", "same", "she", "should",
        "so", "some", "such", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "those", "through", "to", "too", "until", "very", "was",
        "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why",
        "with", "would", "you", "your",
    })


def is_meaningful_token(token: str, min_latin_len: int = 2) -> bool:
    """
    Determines if a token should be preserved for factual grounding.
    Preserves CJK characters (which are single-character morphemes), digits,
    and Latin/Cyrillic words with length >= min_latin_len.
    """
    if not token:
        return False
    if _CJK_RE.search(token):
        return True
    if token.isdigit():
        return True
    return len(token) >= min_latin_len


def get_stopwords(
    language: str = "auto",
    text: str = "",
    include_negations: bool = False,
) -> frozenset[str]:
    """
    Retrieves stop words for a language (or auto-detected from text).
    Enforces the Forensic Keep-List: unless include_negations=True, all negation words
    and directional/quantitative comparators are stripped from the stop word set
    so they are never masked or ignored during grounding.
    """
    effective_lang = language.lower().split("-")[0] if language != "auto" else detect_language(text)
    base_stops = set(_load_spacy_lang_stopwords(effective_lang))

    if not include_negations:
        base_stops -= MULTILINGUAL_NEGATIONS
        base_stops -= FORENSIC_COMPARATORS

    return frozenset(base_stops)


def normalize_numbers(text: str) -> str:
    """
    Normalize comma-separated (1,000,000) and European period-separated (1.000.000) numbers
    to plain unformatted digits for consistent token matching across financial documents,
    without corrupting 3-decimal US numbers (e.g. 0.125, 1,000.250).
    """
    if not text:
        return ""

    # 1. Normalize European full numbers with decimal comma: 1.000.000,50 -> 1000000.50
    res = re.sub(
        r"\b\d{1,3}(?:\.\d{3})+,\d+\b%?",
        lambda m: m.group(0).replace(".", "").replace(",", "."),
        text,
    )

    # 2. Normalize US/UK comma grouping with optional period decimal: 1,000,000.50 or 1,000.250 -> 1000000.50 / 1000.250
    res = re.sub(
        r"\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b%?",
        lambda m: m.group(0).replace(",", ""),
        res,
    )

    # 3. Normalize multi-period European grouping without decimal: 1.000.000 -> 1000000 (at least two period groups)
    res = re.sub(r"\b\d{1,3}(?:\.\d{3}){2,}\b", lambda m: m.group(0).replace(".", ""), res)

    # 4. Normalize single-period European grouping with 000: 100.000 -> 100000, 5.000 -> 5000 (avoids touching 0.125)
    res = re.sub(r"\b[1-9]\d{0,2}\.000\b", lambda m: m.group(0).replace(".", ""), res)

    # 5. Normalize space grouping: 1 000 000 -> 1000000
    res = re.sub(r"\b\d+(?: \d{3})+\b", lambda m: m.group(0).replace(" ", ""), res)

    # 6. Normalize standalone European decimal commas: 5,5% -> 5.5% (1 or 2 digits after comma)
    res = re.sub(r"(\b\d+),(\d{1,2}\b%?)", r"\1.\2", res)

    return res


def stem_word(word: str) -> str:
    """Lightweight stemmer that avoids over-stemming short words (e.g. 'bed', 'string', 'series')."""
    w = word.lower()
    if len(w) <= 4:
        return w
    return re.sub(r"(ing|ed|es|s|tion|ly)$", "", w)
