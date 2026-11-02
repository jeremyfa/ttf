# ttf

Runtime TrueType / OpenType font support in pure Haxe: font parsing, metrics, glyph outlines, rasterization, a simple shaper with font fallback, and a glyph atlas.

It is original code written for [Ceramic](https://ceramic-engine.com) (the `ttf` plugin uses it to display `.ttf` / `.otf` fonts without precomputed bitmap fonts) and for the GPUI port of Ceramic (text shaping, line layout, glyph atlas). It does not depend on Ceramic and runs on every Haxe target. Its only dependency is [plutovg](../plutovg) (the pure Haxe port of plutovg), for `PathOutlineSink`. Glyphs are rasterized by `GrayRaster`, a port of the scan converter of [zeno](https://github.com/dfrg/zeno) (the rasterizer of swash, MIT / Apache-2.0, see the header of `GrayRaster.hx`). Color glyphs follow swash too (`ttf.color`, MIT / Apache-2.0), and `morx` follows HarfBuzz (`ttf.layout.Morx`, Old MIT), see the headers of those files.

## Features

- **Containers**: TrueType (`.ttf`), OpenType with CFF or CFF2 outlines (`.otf`), collections (`.ttc` / `.otc`). Large fonts can be loaded from a `FontSource` (`Font.fromSource()`): only the table directory and the small tables are read, bitmap tables (`sbix`, `CBDT`...) stay in the file and are read glyph by glyph (Apple Color Emoji: about 750 KB read of 192 MB).
- **Tables**: `cmap` (formats 0, 4, 6, 10, 12, 13 and 14 for variation sequences), `head`, `hhea`, `hmtx`, `maxp`, `OS/2`, `post`, `name`, `glyf` / `loca` (quadratic outlines, composite glyphs with scales, 2x2 transforms and point matching), `CFF ` and `CFF2` (Type 2 charstrings, subroutines, CID-keyed fonts, `blend` resolved to the default instance), `GDEF`, `GSUB`, `GPOS`, `kern` (format 0).
- **Metrics** shaped like GPUI's `FontMetrics`: units per em, ascent, descent, line gap (HarfBuzz rules), underline position and thickness, cap height, x height, bounding box. Per glyph: advance, left side bearing, control box, typographic bounds.
- **Rasterization**: 8-bit coverage bitmaps without hinting, at any size, with a subpixel offset (GPUI renders 4 horizontal subpixel variants). TrueType outlines are scaled to 26.6 fixed point exactly like FreeType and skrifa (`Font.outlineScaled()`), then scanned by `GrayRaster` (zeno's port of FreeType's smooth rasterizer): masks and placement are bit exact with swash's unhinted rendering (`Render` with `hint(false)`, `Format::Alpha`), the one GPUI's font file based text system uses.
- **Shaping** (`ttf.shape.Shaper`), for horizontal left to right text:
  - `GSUB` lookups 1 (single), 2 (multiple), 3 (alternate), 4 (ligature), 5 and 6 (context and chained context, formats 1 to 3), 7 (extension);
  - `GPOS` lookups 1 (single), 2 (pair, formats 1 and 2), 4 (mark to base), 6 (mark to mark), 7 and 8 (context), 9 (extension), or the legacy `kern` table;
  - lookup flags (ignore marks, ligatures, base glyphs, mark filtering sets, mark attachment classes);
  - default features like HarfBuzz (`ccmp`, `locl`, `rlig`, `rclt`, `calt`, `clig`, `liga`, `kern`, `mark`, `mkmk`...), toggled with `Features.with(tag, enabled)`;
  - per character font fallback through a fallback chain (same rules as GPUI: ASCII stays on the primary font, then the current fallback, then the first fallback that maps the character);
  - HarfBuzz's normalization fallbacks: a Unicode space missing from the font (U+2000 to U+200A, U+202F, U+205F, U+3000) is drawn with the space glyph and HarfBuzz's fallback advance, a missing U+2011 with the U+2010 hyphen;
  - output shaped like GPUI's `LineLayout` / `ShapedRun` / `ShapedGlyph`, with UTF-8 byte offsets as glyph indices.
- **Color glyphs** (`ttf.color`, `Font.color()`), rendered like swash renders emoji for GPUI's font file based text system: `COLR` version 0 layers with `CPAL` palette 0, then `sbix` (Apple) or `CBDT` / `CBLC` (Google) PNG bitmaps from the first strike at least as large as the size, scaled with a Mitchell filter; RGBA with straight alpha. Includes a pure Haxe inflate and PNG decoder (every color type and depth, interlacing), Apple's `flip` glyphs, and Apple Color Emoji's placement. Emoji sequences (emoji presentation, variation selector 16, skin tones, regional indicators) prefer the fonts with color glyphs in the fallback chain (`Shaper.isEmojiPresentation`; with `Shaper.primaryKeepsCoveredEmoji`, like cosmic-text, a cluster the primary font maps stays on it), and emoji sequences are one cluster like HarfBuzz's.
- **`morx`** (`ttf.layout.Morx`), Apple's substitution table, for fonts without `GSUB` (like HarfBuzz): noncontextual, contextual and ligature subtables with their default features (Apple Color Emoji's ZWJ sequences, skin tones, flags, keycaps).
- **Glyph atlas** (`ttf.atlas`): 8-bit pages with shelf packing, dirty rectangles for partial uploads, least recently used page eviction.
- **UTF-8 helpers** (`ttf.Utf8`): code point iteration over Haxe strings, UTF-8 byte offsets and conversions with UTF-16 indices.

## Usage

```haxe
import ttf.Font;
import ttf.GlyphRasterizer;
import ttf.shape.FontRun;
import ttf.shape.Shaper;

var font = Font.fromBytes(bytes);          // Font.fromBytes(bytes, 1) for the second face of a collection
trace(font.familyName, font.styleName);    // Inter Regular

var m = font.metrics;                      // font units
var ascentPx = m.ascent * 16 / m.unitsPerEm;

// Shape a line (positions in pixels for the given size, indices in UTF-8 bytes)
var shaper = new Shaper();
var text = 'Office -> AVATAR';
var line = shaper.layoutLine(text, 16, [new FontRun(ttf.Utf8.byteLength(text), font, [fallbackFont])]);
for (run in line.runs)
    for (glyph in run.glyphs)
        trace(run.font.familyName, glyph.id, glyph.x, glyph.index);

// Rasterize a glyph at 16px with a quarter pixel horizontal offset
var rasterizer = new GlyphRasterizer();
var bitmap = rasterizer.rasterize(font, font.glyphForChar('g'.code), 16, 0.25, 0);
// bitmap.width x bitmap.height coverage bytes in bitmap.data, placed at (bitmap.left, -bitmap.top)
```

Outlines can also be read directly with any `OutlineSink` (`font.outline(gid, sink)`), or appended to a plutovg `Path` with `PathOutlineSink`.

## Not supported (yet)

- Complex scripts: Arabic, Hebrew and other right to left scripts, bidirectional text, Indic, Thai, Khmer... (no script specific shaping engine). Latin, Greek, Cyrillic and other simple scripts are covered.
- Unicode normalization (composition / decomposition of combining sequences) and fallback mark positioning for fonts without `GPOS` mark attachment.
- Grapheme cluster segmentation: iteration is done by code point; combining marks, variation selectors, joiners and the parts of emoji sequences are kept with the previous character.
- `GPOS` cursive attachment (type 3) and mark to ligature (type 5), `GSUB` reverse chained substitution (type 8), device tables.
- Variable fonts (`fvar`, `avar`, `gvar`, `HVAR`, CFF2 variations): the default instance is used.
- `COLR` version 1 paint graphs, `SVG ` glyphs, monochrome bitmap strikes (`EBDT`), `morx` insertion and rearrangement subtables, `kerx`.
- Hinting (TrueType instructions and CFF hints are ignored), vertical layout, the deprecated `seac` form of CFF `endchar`.

## Tests

`test/` contains a runner without dependencies, which compares the library with reference data produced by **fontTools**, **HarfBuzz** and **FreeType**:

- metrics and names (HarfBuzz font extents, `post`, `OS/2`, `head`), `cmap` lookups, advances and side bearings;
- outline control boxes and signed areas of hundreds of glyphs per font (fontTools pens), for `glyf`, `CFF` and `CFF2` fonts and collections;
- shaping of test strings (glyph ids, clusters, positions) against HarfBuzz with its default features: kerning, contextual alternates and code ligatures of JetBrains Mono, mark attachment, Greek and Cyrillic text, legacy `kern` table and `liga`;
- glyph coverage bitmaps against FreeType unhinted grayscale rendering at several sizes and subpixel offsets (bounds must match exactly; the coverage differs by at most a few levels on curves because FreeType 2.13 subdivides quadratic curves slightly differently from zeno, which follows an older FreeType);
- color glyphs (`sbix`, `CBDT`, `COLR` test fonts, and Apple Color Emoji when present) against swash 0.2.10 (`test/reference/color.json`, made by `test/reference-gen/swash-color`): placement exactly, pixels within 2 levels;
- `morx` ligatures of Apple Color Emoji and the clusters of emoji sequences against HarfBuzz's `hb-shape` (`test/reference/morx.json`, made by `test/reference-gen/gen_morx_reference.py`).

```sh
cd test
./run.sh /path/to/haxe                                         # JS, runs with node
./run-cpp.sh /path/to/hxcpp /path/to/haxe /path/to/haxelib     # hxcpp
./run-interp.sh /path/to/haxe                                  # Haxe interpreter (eval)
```

The plutovg library is expected next to this one (`../plutovg`, as in `ceramic/git`). Reference data is in `test/reference/reference.json`, generated by `test/reference-gen/gen_reference.py` (`pip install fonttools uharfbuzz freetype-py`, then run it from `test/`). The derived test fonts are built by `test/reference-gen/make_test_fonts.py`, the synthetic color test fonts (`SbixTest.ttf`, `CbdtTest.ttf`, `ColrTest.ttf`) by `test/reference-gen/make_color_fonts.py`.

## Fonts and credits

The test fonts are not covered by the MIT license of this library:

- [Inter](https://github.com/rsms/inter) 4.1, Copyright (c) 2016 The Inter Project Authors, SIL Open Font License 1.1 (`test/fonts/OFL-Inter.txt`).
- [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) 2.304, Copyright 2020 The JetBrains Mono Project Authors, SIL Open Font License 1.1 (`test/fonts/OFL-JetBrainsMono.txt`).

`test/fonts/Inter-Regular.ttf`, `Inter-Regular.otf` and `JetBrainsMono-Regular.ttf` are copied unchanged from the official release archives. `Collection-subset.ttc` (ASCII subsets of both fonts in a collection) and `Inter-CFF2-subset.otf` (ASCII subset of Inter converted to CFF2) are derived from them with fontTools, under the same license. `KernLigaTest.ttf` is a synthetic font made of boxes, generated by `make_test_fonts.py`.

## License

MIT, see [LICENSE](LICENSE).
