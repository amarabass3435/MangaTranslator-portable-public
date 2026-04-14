import io
import os
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from fontTools.ttLib import TTFont

from utils.exceptions import FontError
from utils.logging import log_message


class LRUCache:
    """Simple LRU cache implementation to prevent unbounded memory growth."""

    def __init__(self, max_size: int = 100):
        self.max_size = max_size
        self.cache = OrderedDict()

    def get(self, key):
        if key in self.cache:
            value = self.cache.pop(key)
            self.cache[key] = value
            return value
        return None

    def put(self, key, value):
        if key in self.cache:
            self.cache.pop(key)
        elif len(self.cache) >= self.max_size:
            self.cache.popitem(last=False)
        self.cache[key] = value

    def __contains__(self, key):
        return key in self.cache

    def __delitem__(self, key):
        if key in self.cache:
            del self.cache[key]


_font_data_cache = LRUCache(max_size=50)
_font_features_cache = LRUCache(max_size=50)
_font_cmap_cache = LRUCache(max_size=50)
_font_variants_cache: Dict[str, Dict[str, Optional[Path]]] = {}
_font_fallback_resolution_cache: Dict[
    Tuple[Tuple[int, ...], str, str], Optional[str]
] = {}

# Font style detection keywords
FONT_KEYWORDS = {
    "bold": {"bold", "heavy", "black"},
    "italic": {"italic", "oblique", "slanted", "inclined"},
    "regular": {"regular", "normal", "roman", "medium"},
}

ARABIC_BLOCK_RANGES = (
    (0x0600, 0x06FF),
    (0x0750, 0x077F),
    (0x08A0, 0x08FF),
    (0xFB50, 0xFDFF),
    (0xFE70, 0xFEFF),
)

ARABIC_FONT_NAME_HINTS = (
    "arabic",
    "amiri",
    "scheherazade",
    "naskh",
    "nastaliq",
    "geeza",
    "traditional arabic",
    "tahoma",
    "arial",
    "segoe ui",
)


def _is_arabic_codepoint(codepoint: int) -> bool:
    return any(start <= codepoint <= end for start, end in ARABIC_BLOCK_RANGES)


def _extract_required_codepoints(text: str) -> Set[int]:
    required: Set[int] = set()
    for char in text:
        if char == "*" or char.isspace():
            continue
        required.add(ord(char))
    return required


def _iter_font_files(directory: Path) -> List[Path]:
    if not directory.exists() or not directory.is_dir():
        return []
    patterns = ("*.ttf", "*.otf", "*.ttc", "*.otc")
    files: List[Path] = []
    for pattern in patterns:
        files.extend(directory.glob(pattern))
    return files


def _get_system_font_dirs() -> List[Path]:
    if os.name == "nt":
        windows_dir = Path(os.environ.get("WINDIR", r"C:\\Windows"))
        return [windows_dir / "Fonts"]

    if sys.platform == "darwin":
        return [
            Path("/System/Library/Fonts"),
            Path("/Library/Fonts"),
            Path.home() / "Library" / "Fonts",
        ]

    return [
        Path("/usr/share/fonts"),
        Path("/usr/local/share/fonts"),
        Path.home() / ".fonts",
        Path.home() / ".local" / "share" / "fonts",
    ]


def find_fallback_font_for_text(
    text: str,
    preferred_font_dir: Optional[str] = None,
    preferred_font_path: Optional[str] = None,
    verbose: bool = False,
) -> Optional[Path]:
    """
    Find a fallback font that supports the text when the selected pack does not.

    Search order:
    1) Preferred font file (if provided)
    2) Preferred font directory
    3) Sibling font-pack directories
    4) System font directories
    """
    required_codepoints = _extract_required_codepoints(text)
    if not required_codepoints:
        return None

    preferred_dir_path: Optional[Path] = None
    if preferred_font_dir:
        try:
            preferred_dir_path = Path(preferred_font_dir).resolve()
        except Exception:
            preferred_dir_path = None

    preferred_path_resolved: Optional[Path] = None
    if preferred_font_path:
        try:
            preferred_path_resolved = Path(preferred_font_path).resolve()
        except Exception:
            preferred_path_resolved = None

    cache_key = (
        tuple(sorted(required_codepoints)),
        str(preferred_dir_path) if preferred_dir_path else "",
        str(preferred_path_resolved) if preferred_path_resolved else "",
    )
    if cache_key in _font_fallback_resolution_cache:
        cached = _font_fallback_resolution_cache[cache_key]
        return Path(cached) if cached else None

    candidates: List[Path] = []
    seen: Set[str] = set()

    def add_candidate(path: Path) -> None:
        try:
            resolved = path.resolve()
        except Exception:
            return
        key = str(resolved)
        if key in seen:
            return
        if not resolved.exists() or not resolved.is_file():
            return
        seen.add(key)
        candidates.append(resolved)

    if preferred_path_resolved is not None:
        add_candidate(preferred_path_resolved)

    if preferred_dir_path is not None and preferred_dir_path.exists():
        for font_file in _iter_font_files(preferred_dir_path):
            add_candidate(font_file)

        parent_dir = preferred_dir_path.parent
        if parent_dir.exists() and parent_dir.is_dir():
            sibling_dirs = sorted(
                [
                    d
                    for d in parent_dir.iterdir()
                    if d.is_dir() and d.resolve() != preferred_dir_path
                ],
                key=lambda p: p.name.lower(),
            )
            for sibling_dir in sibling_dirs:
                for font_file in _iter_font_files(sibling_dir):
                    add_candidate(font_file)

    for system_dir in _get_system_font_dirs():
        if system_dir.exists() and system_dir.is_dir():
            for font_file in _iter_font_files(system_dir):
                add_candidate(font_file)

    if not candidates:
        _font_fallback_resolution_cache[cache_key] = None
        return None

    required_count = len(required_codepoints)
    contains_arabic = any(_is_arabic_codepoint(cp) for cp in required_codepoints)

    best_font: Optional[Path] = None
    best_score: Optional[Tuple[int, int, int, int, int]] = None

    for index, candidate in enumerate(candidates):
        cmap = get_font_cmap(str(candidate))
        if not cmap:
            continue

        supported_count = len(required_codepoints.intersection(cmap))
        if supported_count <= 0:
            continue

        full_support = 1 if supported_count == required_count else 0
        preferred_dir_bonus = (
            1 if preferred_dir_path is not None and candidate.parent == preferred_dir_path else 0
        )
        name_lower = candidate.name.lower()
        arabic_name_bonus = (
            1
            if contains_arabic
            and any(hint in name_lower for hint in ARABIC_FONT_NAME_HINTS)
            else 0
        )

        score = (
            full_support,
            arabic_name_bonus,
            preferred_dir_bonus,
            supported_count,
            -index,
        )
        if best_score is None or score > best_score:
            best_score = score
            best_font = candidate

    if best_font is None:
        _font_fallback_resolution_cache[cache_key] = None
        return None

    _font_fallback_resolution_cache[cache_key] = str(best_font)
    coverage_pct = (best_score[3] / required_count) * 100.0 if best_score else 0.0
    log_message(
        f"Fallback font selected: {best_font.name} ({coverage_pct:.1f}% glyph coverage)",
        verbose=verbose,
    )
    return best_font


def get_font_features(font_path: str) -> Dict[str, List[str]]:
    """
    Uses fontTools to list GSUB and GPOS features in a font file. Caches results.

    Args:
        font_path: Path to the font file.

    Returns:
        Dictionary with 'GSUB' and 'GPOS' keys, each containing a list of feature tags.
    """
    cached_features = _font_features_cache.get(font_path)
    if cached_features is not None:
        return cached_features

    features = {"GSUB": [], "GPOS": []}
    try:
        font = TTFont(font_path, fontNumber=0)

        if (
            "GSUB" in font
            and hasattr(font["GSUB"].table, "FeatureList")
            and font["GSUB"].table.FeatureList
        ):
            features["GSUB"] = sorted(
                [fr.FeatureTag for fr in font["GSUB"].table.FeatureList.FeatureRecord]
            )

        if (
            "GPOS" in font
            and hasattr(font["GPOS"].table, "FeatureList")
            and font["GPOS"].table.FeatureList
        ):
            features["GPOS"] = sorted(
                [fr.FeatureTag for fr in font["GPOS"].table.FeatureList.FeatureRecord]
            )

    except ImportError:
        log_message(
            "fontTools not available - font features disabled", always_print=True
        )
    except Exception as e:
        log_message(
            f"Font feature inspection failed for {os.path.basename(font_path)}: {e}",
            always_print=True,
        )

    _font_features_cache.put(font_path, features)
    return features


def get_font_cmap(font_path: str) -> set:
    """
    Returns the set of Unicode codepoints supported by the font.

    Uses fontTools to extract the best cmap table from the font file.
    Results are cached to avoid repeated font parsing.

    Args:
        font_path: Path to the font file.

    Returns:
        Set of integer codepoints (Unicode code points) supported by the font.
        Returns an empty set if the font cannot be read or has no cmap.
    """
    cached_cmap = _font_cmap_cache.get(font_path)
    if cached_cmap is not None:
        return cached_cmap

    supported_codepoints: set = set()
    try:
        font = TTFont(font_path, fontNumber=0)
        cmap = font.getBestCmap()
        if cmap:
            supported_codepoints = set(cmap.keys())
    except Exception as e:
        log_message(
            f"Failed to extract cmap from {os.path.basename(font_path)}: {e}",
            always_print=True,
        )

    _font_cmap_cache.put(font_path, supported_codepoints)
    return supported_codepoints


def sanitize_text_for_font(text: str, font_path: str, verbose: bool = False) -> str:
    """
    Removes characters from text that are not supported by the font's cmap.

    This prevents "tofu" characters (▯) from appearing in rendered text.
    Style markers (*, **, ***) are preserved even if asterisk is not in the font,
    since they are stripped during text processing and never actually rendered.

    Args:
        text: The text to sanitize.
        font_path: Path to the font file to check against.
        verbose: Whether to print detailed logs.

    Returns:
        Sanitized text with unsupported characters removed.
    """
    if not text:
        return text

    supported_codepoints = get_font_cmap(font_path)

    if not supported_codepoints:
        log_message(
            f"Could not get cmap for {os.path.basename(font_path)}, skipping sanitization",
            verbose=verbose,
        )
        return text

    # Characters to always preserve (style markers used in markdown-like formatting)
    STYLE_MARKER_CHARS = {"*"}
    WHITESPACE_CHARS = {" ", "\t", "\n", "\r"}

    removed_chars: List[str] = []
    sanitized_chars: List[str] = []

    for char in text:
        codepoint = ord(char)

        if char in STYLE_MARKER_CHARS or char in WHITESPACE_CHARS:
            sanitized_chars.append(char)
        elif codepoint in supported_codepoints:
            sanitized_chars.append(char)
        else:
            removed_chars.append(char)

    if removed_chars:
        unique_removed = sorted(set(removed_chars), key=lambda c: ord(c))
        char_descriptions = [f"'{c}' (U+{ord(c):04X})" for c in unique_removed[:10]]
        if len(unique_removed) > 10:
            char_descriptions.append(f"... and {len(unique_removed) - 10} more")

        log_message(
            f"Removed {len(removed_chars)} unsupported character(s) from text: "
            f"{', '.join(char_descriptions)}",
            always_print=True,
        )

    return "".join(sanitized_chars)


def _validate_font_file(font_file: Path, verbose: bool = False) -> bool:
    """
    Validate that a font file is not corrupt by attempting to load it with TTFont.

    Args:
        font_file: Path to the font file to validate
        verbose: Whether to print detailed logs

    Returns:
        True if font is valid, False if corrupt or invalid
    """
    try:
        # Try to load the font with fontTools to check integrity
        font = TTFont(font_file, fontNumber=0)
        # Basic validation - check if it has required tables
        if "cmap" not in font or "head" not in font:
            log_message(
                f"Font file {font_file.name} appears to be missing required tables",
                verbose=verbose,
                always_print=True,
            )
            return False
        return True
    except Exception as e:
        log_message(
            f"Font file {font_file.name} appears to be corrupt: {e}",
            verbose=verbose,
            always_print=True,
        )
        return False


def find_font_variants(
    font_dir: str, verbose: bool = False
) -> Dict[str, Optional[Path]]:
    """
    Finds regular, italic, bold, and bold-italic font variants (.ttf, .otf)
    in a directory based on filename keywords. Caches results per directory.

    Args:
        font_dir: Directory containing font files.
        verbose: Whether to print detailed logs.

    Returns:
        Dictionary mapping style names ("regular", "italic", "bold", "bold_italic")
        to their respective Path objects, or None if not found.
    """
    resolved_dir = str(Path(font_dir).resolve())
    if resolved_dir in _font_variants_cache:
        return _font_variants_cache[resolved_dir]

    log_message(f"Scanning fonts in {os.path.basename(resolved_dir)}", verbose=verbose)
    font_files: List[Path] = []
    font_variants: Dict[str, Optional[Path]] = {
        "regular": None,
        "italic": None,
        "bold": None,
        "bold_italic": None,
    }
    identified_files: set[Path] = set()

    try:
        font_dir_path = Path(resolved_dir)
        if font_dir_path.exists() and font_dir_path.is_dir():
            font_files = list(font_dir_path.glob("*.ttf")) + list(
                font_dir_path.glob("*.otf")
            )
        else:
            log_message(f"Font directory not found: {font_dir_path}", always_print=True)
            _font_variants_cache[resolved_dir] = font_variants
            return font_variants
    except Exception as e:
        log_message(f"Font directory access error: {e}", always_print=True)
        _font_variants_cache[resolved_dir] = font_variants
        return font_variants

    if not font_files:
        log_message(
            f"No font files found in {os.path.basename(resolved_dir)}",
            always_print=True,
        )
        _font_variants_cache[resolved_dir] = font_variants
        return font_variants

    # Sort by name length (desc) to prioritize more specific names like "BoldItalic" over "Bold"
    font_files.sort(key=lambda x: len(x.name), reverse=True)

    # Pass 1: Combined styles first
    for font_file in font_files:
        if font_file in identified_files:
            continue

        # Validate font file integrity before processing
        if not _validate_font_file(font_file, verbose=verbose):
            continue

        stem_lower = font_file.stem.lower()
        is_bold = any(kw in stem_lower for kw in FONT_KEYWORDS["bold"])
        is_italic = any(kw in stem_lower for kw in FONT_KEYWORDS["italic"])
        assigned = False
        if is_bold and is_italic:
            if not font_variants["bold_italic"]:
                font_variants["bold_italic"] = font_file
                assigned = True
                log_message(f"Found bold-italic: {font_file.name}", verbose=verbose)
        if assigned:
            identified_files.add(font_file)

    # Pass 2: Single styles
    for font_file in font_files:
        if font_file in identified_files:
            continue

        # Validate font file integrity before processing
        if not _validate_font_file(font_file, verbose=verbose):
            continue

        stem_lower = font_file.stem.lower()
        is_bold = any(kw in stem_lower for kw in FONT_KEYWORDS["bold"])
        is_italic = any(kw in stem_lower for kw in FONT_KEYWORDS["italic"])
        assigned = False
        if is_bold and not is_italic:
            if not font_variants["bold"]:
                font_variants["bold"] = font_file
                assigned = True
                log_message(f"Found bold: {font_file.name}", verbose=verbose)
        elif is_italic and not is_bold:
            if not font_variants["italic"]:
                font_variants["italic"] = font_file
                assigned = True
                log_message(f"Found italic: {font_file.name}", verbose=verbose)
        if assigned:
            identified_files.add(font_file)

    # Pass 3: Explicit regular matches
    for font_file in font_files:
        if font_file in identified_files:
            continue

        # Validate font file integrity before processing
        if not _validate_font_file(font_file, verbose=verbose):
            continue

        stem_lower = font_file.stem.lower()
        is_regular = any(kw in stem_lower for kw in FONT_KEYWORDS["regular"])
        is_bold = any(kw in stem_lower for kw in FONT_KEYWORDS["bold"])
        is_italic = any(kw in stem_lower for kw in FONT_KEYWORDS["italic"])
        assigned = False
        if is_regular and not is_bold and not is_italic:
            if not font_variants["regular"]:
                font_variants["regular"] = font_file
                assigned = True
                log_message(f"Found regular: {font_file.name}", verbose=verbose)
        if assigned:
            identified_files.add(font_file)

    # Pass 4: Infer regular from files without style keywords
    if not font_variants["regular"]:
        for font_file in font_files:
            if font_file in identified_files:
                continue

            # Validate font file integrity before processing
            if not _validate_font_file(font_file, verbose=verbose):
                continue

            stem_lower = font_file.stem.lower()
            is_bold = any(kw in stem_lower for kw in FONT_KEYWORDS["bold"])
            is_italic = any(kw in stem_lower for kw in FONT_KEYWORDS["italic"])
            if (
                not is_bold
                and not is_italic
                and not any(kw in stem_lower for kw in FONT_KEYWORDS["regular"])
            ):
                font_name_lower = font_file.name.lower()
                is_likely_specific = any(
                    spec in font_name_lower
                    for spec in [
                        "light",
                        "thin",
                        "condensed",
                        "expanded",
                        "semi",
                        "demi",
                        "extra",
                        "ultra",
                        "book",
                        "medium",
                        "black",
                        "heavy",
                    ]
                )
                if not is_likely_specific:
                    font_variants["regular"] = font_file
                    identified_files.add(font_file)
                    log_message(f"Inferred regular: {font_file.name}", verbose=verbose)
                    break

    # Pass 5: Fallback to first available
    if not font_variants["regular"]:
        first_available = next(
            (f for f in font_files if f not in identified_files), None
        )
        if first_available:
            font_variants["regular"] = first_available
            if first_available not in identified_files:
                identified_files.add(first_available)
            log_message(f"Fallback regular: {first_available.name}", verbose=verbose)

    # Pass 6: Final fallback to any variant
    if not font_variants["regular"]:
        backup_regular = next(
            (
                f
                for f in [
                    font_variants.get("bold"),
                    font_variants.get("italic"),
                    font_variants.get("bold_italic"),
                ]
                if f
            ),
            None,
        )
        if backup_regular:
            font_variants["regular"] = backup_regular
            log_message(f"Fallback regular: {backup_regular.name}", verbose=verbose)
        elif font_files:
            font_variants["regular"] = font_files[0]
            log_message(f"Fallback regular: {font_files[0].name}", verbose=verbose)

    if not font_variants["regular"]:
        log_message(
            f"CRITICAL: No regular font found in {os.path.basename(resolved_dir)} - rendering will fail",
            always_print=True,
        )
        raise FontError(f"No regular font found in directory: {resolved_dir}")
    else:
        found_variants = [
            f"{style}: {path.name}" for style, path in font_variants.items() if path
        ]
        log_message(f"Font variants: {', '.join(found_variants)}", verbose=verbose)

    _font_variants_cache[resolved_dir] = font_variants
    return font_variants


def sanitize_font_data(font_path: str, font_data: bytes) -> bytes:
    """
    Analyzes font data for known issues (bad UPM, corrupt kern table) and
    returns a sanitized version of the font data.

    Args:
        font_path: Path to the font file (for logging purposes)
        font_data: Raw font data bytes

    Returns:
        Sanitized font data bytes
    """
    try:
        font_file = io.BytesIO(font_data)
        font = TTFont(font_file, fontNumber=0)

        data_was_modified = False

        if "kern" in font:
            try:
                _ = font["kern"].tables[0].kernTable
            except Exception:
                msg = f"Detected corrupt kern table in {os.path.basename(font_path)}. Removing it."
                log_message(msg, always_print=True)
                del font["kern"]
                data_was_modified = True

        test_glyph_name = None
        cmap = font.getBestCmap()
        if cmap and ord("M") in cmap:
            test_glyph_name = cmap[ord("M")]

        if test_glyph_name and "glyf" in font and "hmtx" in font:
            glyph = font["glyf"][test_glyph_name]
            advance_width = font["hmtx"][test_glyph_name][0]

            # Check for italic style (Bit 1 of macStyle) and allow 30% overhang
            is_italic = (font["head"].macStyle & 0b10) != 0 if "head" in font else False
            tolerance = 1.3 if is_italic else 1.0

            if hasattr(glyph, "xMax") and glyph.xMax > (advance_width * tolerance):
                msg = f"Font {os.path.basename(font_path)} has unreliable metrics. Overriding UPM to 1000."
                log_message(msg, always_print=True)
                font["head"].unitsPerEm = 1000
                data_was_modified = True

        if data_was_modified:
            output_bytes = io.BytesIO()
            font.save(output_bytes)
            return output_bytes.getvalue()
        else:
            return font_data

    except Exception as e:
        log_message(
            f"Font sanitization failed for {os.path.basename(font_path)}: {e}",
            always_print=True,
        )
        return font_data


def load_font_data(font_path: str) -> bytes:
    """
    Loads and sanitizes font data from a file. Uses caching to avoid repeated reads.

    Args:
        font_path: Path to the font file

    Returns:
        Sanitized font data bytes

    Raises:
        FontError: If font file cannot be loaded or is invalid
    """
    font_data = _font_data_cache.get(font_path)
    if font_data is None:
        try:
            with open(font_path, "rb") as f:
                original_font_data = f.read()

            font_data = sanitize_font_data(font_path, original_font_data)
            _font_data_cache.put(font_path, font_data)
        except Exception as e:
            log_message(f"Font file read error: {e}", always_print=True)
            raise FontError(f"Failed to load font file: {font_path}") from e

    return font_data


def load_font_family(font_dir: str, verbose: bool = False) -> Dict[str, Optional[str]]:
    """
    High-level function to load a complete font family from a directory.

    Args:
        font_dir: Directory containing font files
        verbose: Whether to print detailed logs

    Returns:
        Dictionary mapping style names to font file paths (as strings)
    """
    variants = find_font_variants(font_dir, verbose=verbose)
    return {style: str(path) if path else None for style, path in variants.items()}
