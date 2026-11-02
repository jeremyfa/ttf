// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.shape;

import ttf.Font;
import ttf.Utf8;
import ttf.layout.Gdef;
import ttf.layout.GlyphBuffer;
import ttf.shape.LineLayout;

/**
 * A simple OpenType shaper for horizontal, left to right text (Latin,
 * Greek, Cyrillic and other scripts without complex shaping rules).
 *
 * For each font run, characters are mapped to glyphs with `cmap` (with
 * per character fallback through the run's fallback fonts, following
 * GPUI's rules), then `GSUB` lookups (ligatures, contextual alternates...)
 * and `GPOS` lookups (kerning, mark attachment) are applied, or the legacy
 * `kern` table when `GPOS` has no kerning.
 *
 * Not handled: bidirectional text and right to left scripts, scripts that
 * need a dedicated shaping engine (Arabic, Indic, Thai...), Unicode
 * normalization (composition / decomposition) and fallback mark
 * positioning for fonts without `GPOS` marks.
 *
 * ```haxe
 * var shaper = new Shaper();
 * var line = shaper.layoutLine('Hello', 16, [new FontRun(5, font)]);
 * for (run in line.runs)
 *     for (glyph in run.glyphs)
 *         trace(glyph.id, glyph.x, glyph.index);
 * ```
 *
 * A shaper reuses internal buffers: use one instance per thread.
 *
 * By default, advances and offsets are accumulated in font units and
 * scaled once, in double precision. Set `singlePrecision` to compute them
 * like cosmic-text (and so GPUI's text system) instead.
 */
class Shaper {

    /**
     * Single precision mode (off by default): positions, width and metrics
     * follow cosmic-text's `f32` arithmetic (cosmic-text 0.19, src/shape.rs,
     * `shape_fallback` and `layout_to_buffer`). Advances, offsets, ascent and
     * descent are converted to ems with one `f32` division by the units per
     * em, then scaled by the font size with one `f32` multiplication, and the
     * pen position is accumulated in `f32`, glyph by glyph. A glyph's `x` is
     * the pen position plus its scaled x offset, its `y` the opposite of its
     * scaled y offset (like cosmic-text's `LayoutGlyph::physical` at scale 1).
     *
     * cosmic-text sums the line width word by word instead: users that need
     * that sum (or tab stops) can redo it from `advanceUnits`.
     */
    public var singlePrecision:Bool = false;

    /**
     * Characters displayed as emoji by default (Unicode's
     * `Emoji_Presentation`), or null. Emoji prefer the fonts with color
     * glyphs among the primary font and the fallbacks (see `pickFont()`):
     * characters followed by variation selector 16 (U+FE0F) or by a skin
     * tone modifier, and regional indicators, always do; the characters
     * this function accepts do too unless followed by variation selector 15
     * (U+FE0E, text presentation).
     */
    public var isEmojiPresentation:Null<Int->Bool> = null;

    /**
     * When true, a character that asks for an emoji glyph stays on the
     * primary font when that font maps it and the rest of its cluster
     * (variation selectors, joiners and tag characters excepted, the
     * default ignorable characters HarfBuzz hides): cosmic-text's rule,
     * which keeps a cluster on the first font that shapes it without a
     * notdef glyph, so `❤️` stays on a text font that maps `❤`. False (the
     * default): emoji prefer the fonts with color glyphs, the primary font
     * included only if it has color glyphs.
     */
    public var primaryKeepsCoveredEmoji:Bool = false;

    var codePoints:Array<Int> = [];

    var byteOffsets:Array<Int> = [];

    var buffer:GlyphBuffer = new GlyphBuffer();

    var absX:Array<Int> = [];

    var absY:Array<Int> = [];

    static final KERN_FEATURE = ['kern'];

    var pairBuffer:GlyphBuffer = new GlyphBuffer();

    static var kernOnly:Features = null;

    public function new() {}

    /**
     * Kerning between two glyphs of `font`, in font units: how much the
     * second glyph moves because of pair positioning (`GPOS` `kern`
     * feature, or the legacy `kern` table). Useful to fill per character
     * kerning tables (like `ceramic.BitmapFont` ones).
     */
    public function pairKerning(font:Font, left:Int, right:Int, script:Int = Script.LATIN):Int {
        if (kernOnly == null)
            kernOnly = new Features([], ['kern']);
        var buf = pairBuffer;
        buf.clear();
        var gdef = font.gdef;
        var hasClasses = gdef != null && gdef.hasGlyphClasses;
        buf.push(left, 0, hasClasses ? gdef.glyphClass(left) : Gdef.BASE);
        buf.push(right, 1, hasClasses ? gdef.glyphClass(right) : Gdef.BASE);
        var advance = font.advance(left);
        buf.xAdvance[0] = advance;
        buf.xAdvance[1] = font.advance(right);
        var scriptTag = Script.tag(script);
        var gposKerning = false;
        var gpos = font.gpos;
        if (gpos != null) {
            var lookups = gpos.lookupsForKey(kernOnly.id * 8 + script, scriptTag, kernOnly.gpos);
            gposKerning = lookups.length > 0;
            gpos.apply(buf, lookups);
        }
        if (!gposKerning && font.kern != null)
            font.kern.apply(buf);
        return buf.xAdvance[0] + buf.xOffset[1] - advance;
    }

    /**
     * Shapes a single line of text. `runs` cover the text in order, their
     * `len` being UTF-8 byte lengths (like GPUI's `layout_line`).
     */
    public function layoutLine(text:String, fontSize:Float, runs:Array<FontRun>, ?out:LineLayout):LineLayout {

        var layout = out != null ? out : new LineLayout();
        if (singlePrecision)
            fontSize = f32(fontSize);
        layout.fontSize = fontSize;
        layout.width = 0;
        layout.ascent = 0;
        layout.descent = 0;
        layout.runs = [];

        var count = Utf8.decode(text, codePoints, byteOffsets);
        layout.len = count > 0 ? byteOffsets[count - 1] + Utf8.codePointLength(codePoints[count - 1]) : 0;

        var cps = codePoints;
        var offsets = byteOffsets;
        var penX = 0.0;
        var cpIndex = 0;
        var runStart = 0;

        for (r in 0...runs.length) {
            var run = runs[r];
            var runEnd = runStart + run.len;
            var first = cpIndex;
            while (cpIndex < count && offsets[cpIndex] < runEnd)
                cpIndex++;
            runStart = runEnd;
            if (first >= cpIndex)
                continue;

            var features = run.features != null ? run.features : Features.DEFAULT;

            var spanStart = first;
            var spanFont:Font = null;
            var spanScript = Script.COMMON;
            for (k in first...cpIndex) {
                var c = cps[k];
                var continuation = k > first && Utf8.isContinuation(c);
                var font = continuation ? spanFont
                    : pickFont(c, run, spanFont, (c > 0x7F || (k + 1 < cpIndex && cps[k + 1] == 0xFE0F)) && wantsColor(k, cpIndex)
                        && !(primaryKeepsCoveredEmoji && primaryCoversCluster(run.font, k, cpIndex)));
                var script = continuation ? Script.COMMON : Script.of(c);
                if (k == first) {
                    spanFont = font;
                    spanScript = script;
                    continue;
                }
                if (font != spanFont || (script != Script.COMMON && spanScript != Script.COMMON && script != spanScript)) {
                    penX = shapeSpan(layout, spanFont, features, spanScript, spanStart, k, fontSize, penX);
                    spanStart = k;
                    spanFont = font;
                    spanScript = script;
                }
                else if (spanScript == Script.COMMON) {
                    spanScript = script;
                }
            }
            penX = shapeSpan(layout, spanFont, features, spanScript, spanStart, cpIndex, fontSize, penX);
        }

        layout.width = penX;
        return layout;

    }

    /**
     * Font used for a character: ASCII and characters mapped by the primary
     * font use it, then the current fallback if it maps the character, then
     * the first fallback that does (like GPUI's `pick_covering_slot`).
     * Emoji (`color`) look for a font with color glyphs first; other
     * characters for a font without color glyphs first.
     */
    function pickFont(c:Int, run:FontRun, current:Font, color:Bool):Font {
        var primary = run.font;
        var fallbacks = run.fallbacks;
        if (color) {
            // Emoji: the first color font that maps the character, in the same order
            if (primary.hasColorGlyphs && primary.hasChar(c))
                return primary;
            if (current != null && current != primary && current.hasColorGlyphs && current.hasChar(c))
                return current;
            if (fallbacks != null) {
                for (i in 0...fallbacks.length) {
                    var fb = fallbacks[i];
                    if (fb.hasColorGlyphs && fb.hasChar(c))
                        return fb;
                }
            }
        }
        if (c <= 0x7F || fallbacks == null || fallbacks.length == 0)
            return primary;
        if (covers(primary, c))
            return primary;
        // Text presentation: fonts without color glyphs first, then the color
        // fonts in the same order (only fonts with color glyphs change the
        // GPUI rules)
        var colorFallback:Font = null;
        if (current != null && current != primary && covers(current, c)) {
            if (!current.hasColorGlyphs)
                return current;
            colorFallback = current;
        }
        for (i in 0...fallbacks.length) {
            var fb = fallbacks[i];
            if (covers(fb, c)) {
                if (!fb.hasColorGlyphs)
                    return fb;
                if (colorFallback == null)
                    colorFallback = fb;
            }
        }
        return colorFallback != null ? colorFallback : primary;
    }

    /**
     * True if `font` maps the character at `k` and every character of its
     * cluster (as grouped by `shapeSpan()`), except the default ignorable
     * ones (variation selectors, ZWJ, tag characters), see
     * `primaryKeepsCoveredEmoji`.
     */
    function primaryCoversCluster(font:Font, k:Int, end:Int):Bool {
        var cps = codePoints;
        if (!covers(font, cps[k]))
            return false;
        var previous = cps[k];
        var regionalIndicators = previous >= 0x1F1E6 && previous <= 0x1F1FF ? 1 : 0;
        var i = k + 1;
        while (i < end) {
            var c = cps[i];
            var isRegional = c >= 0x1F1E6 && c <= 0x1F1FF;
            var isTag = c >= 0xE0020 && c <= 0xE007F;
            var continuation = Utf8.isContinuation(c) || (previous == 0x200D && isPictographic(c))
                || (isRegional && (regionalIndicators & 1) == 1) || isTag;
            if (!continuation)
                break;
            var ignorable = Utf8.isVariationSelector(c) || c == 0x200D || isTag;
            if (!ignorable && !covers(font, c))
                return false;
            regionalIndicators = isRegional ? regionalIndicators + 1 : 0;
            previous = c;
            i++;
        }
        return true;
    }

    /** Approximation of Unicode's `Extended_Pictographic` (used after a ZWJ only) */
    static inline function isPictographic(c:Int):Bool {
        return c >= 0x1F000 || (c >= 0x2100 && c <= 0x2BFF) || c == 0xA9 || c == 0xAE || c == 0x203C
            || c == 0x2049 || c == 0x3030 || c == 0x303D || c == 0x3297 || c == 0x3299;
    }

    /**
     * True if the character at `k` (of the code points before `end`) asks
     * for an emoji (color) glyph, see `isEmojiPresentation`.
     */
    function wantsColor(k:Int, end:Int):Bool {
        var c = codePoints[k];
        var next = k + 1 < end ? codePoints[k + 1] : -1;
        if (next == 0xFE0F || (next >= 0x1F3FB && next <= 0x1F3FF))
            return true;
        if (next == 0xFE0E)
            return false;
        if (c >= 0x1F1E6 && c <= 0x1F1FF)
            return true;
        return c > 0x7F && isEmojiPresentation != null && isEmojiPresentation(c);
    }

    /**
     * True if `font` can render `c`: it maps the character, or HarfBuzz's
     * normalization fallbacks apply (a missing Unicode space is drawn with
     * the space glyph, a missing U+2011 with the U+2010 hyphen).
     */
    static function covers(font:Font, c:Int):Bool {
        if (font.hasChar(c))
            return true;
        if (spaceFallbackType(c) != NOT_SPACE)
            return font.hasChar(0x20);
        if (c == 0x2011)
            return font.hasChar(0x2010);
        return false;
    }

    // Space fallback types (HarfBuzz `hb_unicode_funcs_t::space_t`)
    static inline final NOT_SPACE = 0;
    static inline final SPACE_EM = 1;
    static inline final SPACE_EM_2 = 2;
    static inline final SPACE_EM_3 = 3;
    static inline final SPACE_EM_4 = 4;
    static inline final SPACE_EM_5 = 5;
    static inline final SPACE_EM_6 = 6;
    static inline final SPACE_EM_16 = 16;
    static inline final SPACE_4_EM_18 = 17;
    static inline final SPACE = 18;
    static inline final SPACE_FIGURE = 19;
    static inline final SPACE_PUNCTUATION = 20;
    static inline final SPACE_NARROW = 21;

    /** HarfBuzz `space_fallback_type`: how a missing space character is rendered. */
    static function spaceFallbackType(c:Int):Int {
        return switch c {
            case 0x0020 | 0x00A0: SPACE;
            case 0x2000 | 0x2002: SPACE_EM_2;
            case 0x2001 | 0x2003 | 0x3000: SPACE_EM;
            case 0x2004: SPACE_EM_3;
            case 0x2005: SPACE_EM_4;
            case 0x2006: SPACE_EM_6;
            case 0x2007: SPACE_FIGURE;
            case 0x2008: SPACE_PUNCTUATION;
            case 0x2009: SPACE_EM_5;
            case 0x200A: SPACE_EM_16;
            case 0x202F: SPACE_NARROW;
            case 0x205F: SPACE_4_EM_18;
            case _: NOT_SPACE;
        }
    }

    /** HarfBuzz `_hb_ot_shape_fallback_spaces`: advance of a fallback space, in font units. */
    static function fallbackSpaceAdvance(font:Font, spaceType:Int, advance:Int):Int {
        var upem = font.unitsPerEm;
        if (spaceType >= SPACE_EM && spaceType <= SPACE_EM_16)
            return Std.int((upem + Std.int(spaceType / 2)) / spaceType);
        return switch spaceType {
            case SPACE_4_EM_18: Std.int(upem * 4 / 18);
            case SPACE_FIGURE:
                var result = advance;
                for (digit in '0'.code...'9'.code + 1) {
                    var g = font.glyphForChar(digit);
                    if (g != 0) {
                        result = font.advance(g);
                        break;
                    }
                }
                result;
            case SPACE_PUNCTUATION:
                var g = font.glyphForChar('.'.code);
                if (g == 0)
                    g = font.glyphForChar(','.code);
                g != 0 ? font.advance(g) : advance;
            case SPACE_NARROW:
                // Half of the space (like HarfBuzz)
                Std.int(advance / 2);
            case _: advance;
        }
    }

    /** Clusters of fallback spaces in the span being shaped, with their space type */
    var fallbackSpaces:Array<Int> = [];

    function shapeSpan(layout:LineLayout, font:Font, features:Features, script:Int, start:Int, end:Int, fontSize:Float, penX:Float):Float {

        var buf = buffer;
        buf.clear();
        if (fallbackSpaces.length > 0)
            fallbackSpaces.resize(0);

        var cps = codePoints;
        var offsets = byteOffsets;
        var gdef = font.gdef;
        var hasClasses = gdef != null && gdef.hasGlyphClasses;
        var lastCp = -1;
        var lastCluster = offsets[start];
        var morx = font.morx;

        var previous = -1;
        var regionalIndicators = 0;
        for (k in start...end) {
            var c = cps[k];
            // Characters that continue a cluster (marks, joiners...) share its
            // index, and like HarfBuzz's `hb_set_unicode_props`, so do the
            // pictograph after a ZWJ, the second regional indicator of a pair
            // and tag characters (emoji sequences are one cluster)
            var isRegional = c >= 0x1F1E6 && c <= 0x1F1FF;
            var continuation = k > start && (Utf8.isContinuation(c)
                || (previous == 0x200D && isPictographic(c))
                || (isRegional && (regionalIndicators & 1) == 1)
                || (c >= 0xE0020 && c <= 0xE007F));
            regionalIndicators = isRegional ? regionalIndicators + 1 : 0;
            previous = c;
            var cluster = continuation ? lastCluster : offsets[k];
            lastCluster = cluster;
            if (Utf8.isVariationSelector(c)) {
                if (buf.length > 0 && lastCp >= 0) {
                    var g = font.glyphForCharVariant(lastCp, c);
                    if (g != 0 && g != buf.glyphs[buf.length - 1]) {
                        buf.glyphs[buf.length - 1] = g;
                        if (hasClasses)
                            buf.classes[buf.length - 1] = gdef.glyphClass(g);
                    }
                    else if (morx != null && font.hasChar(c)) {
                        // AAT fonts match variation selectors in their
                        // sequences (like HarfBuzz without a cmap 14 mapping)
                        buf.push(font.glyphForChar(c), cluster, Gdef.HIDDEN);
                    }
                }
                continue;
            }
            var gid = font.glyphForChar(c);
            if (gid == 0) {
                // HarfBuzz normalization fallbacks for characters the font lacks
                var spaceType = spaceFallbackType(c);
                if (spaceType != NOT_SPACE && font.hasChar(0x20)) {
                    gid = font.glyphForChar(0x20);
                    if (spaceType != SPACE) {
                        fallbackSpaces.push(cluster);
                        fallbackSpaces.push(spaceType);
                    }
                }
                else if (c == 0x2011 && font.hasChar(0x2010)) {
                    gid = font.glyphForChar(0x2010);
                }
            }
            if (gid == 0 && Utf8.isDefaultIgnorable(c)) {
                // Rendered as an invisible space (like HarfBuzz)
                buf.push(0, cluster, Gdef.HIDDEN);
                continue;
            }
            var glyphClass = hasClasses ? gdef.glyphClass(gid) : (Utf8.isMark(c) ? Gdef.MARK : Gdef.BASE);
            // AAT fonts map default ignorables (ZWJ...) to glyphs their
            // `morx` sequences match; they stay hidden unless substituted
            if (morx != null && Utf8.isDefaultIgnorable(c))
                glyphClass = Gdef.HIDDEN;
            buf.push(gid, cluster, glyphClass);
            lastCp = c;
        }

        if (buf.length == 0)
            return penX;

        var scriptTag = Script.tag(script);
        var key = features.id * 8 + script;

        var gsub = font.gsub;
        if (gsub != null)
            gsub.apply(buf, gsub.lookupsForKey(key, scriptTag, features.gsub));
        else if (morx != null) {
            morx.apply(buf, font.numGlyphs);
            if (hasClasses) {
                for (i in 0...buf.length) {
                    if (buf.classes[i] != Gdef.HIDDEN)
                        buf.classes[i] = gdef.glyphClass(buf.glyphs[i]);
                }
            }
        }

        for (i in 0...buf.length)
            buf.xAdvance[i] = font.advance(buf.glyphs[i]);

        // Advances of fallback spaces (before GPOS, like HarfBuzz)
        if (fallbackSpaces.length > 0) {
            var spaceGlyph = font.glyphForChar(0x20);
            for (i in 0...buf.length) {
                if (buf.glyphs[i] != spaceGlyph)
                    continue;
                var k = 0;
                while (k < fallbackSpaces.length) {
                    if (fallbackSpaces[k] == buf.clusters[i]) {
                        buf.xAdvance[i] = fallbackSpaceAdvance(font, fallbackSpaces[k + 1], buf.xAdvance[i]);
                        break;
                    }
                    k += 2;
                }
            }
        }

        var gpos = font.gpos;
        var gposKerning = false;
        if (gpos != null) {
            gpos.apply(buf, gpos.lookupsForKey(key, scriptTag, features.gpos));
            gposKerning = gpos.lookupsForKey(-1 - script, scriptTag, KERN_FEATURE).length > 0;
        }
        if (features.kerning && font.kern != null && !gposKerning)
            font.kern.apply(buf);

        // Marks do not advance the pen, hidden characters become empty spaces
        for (i in 0...buf.length) {
            var glyphClass = buf.classes[i];
            if (glyphClass == Gdef.MARK) {
                buf.xAdvance[i] = 0;
            }
            else if (glyphClass == Gdef.HIDDEN) {
                buf.glyphs[i] = font.glyphForChar(0x20);
                buf.xAdvance[i] = 0;
                buf.xOffset[i] = 0;
                buf.yOffset[i] = 0;
            }
        }

        // Emit glyphs
        var runs = layout.runs;
        var run:ShapedRun = runs.length > 0 ? runs[runs.length - 1] : null;
        if (run == null || run.font != font) {
            run = new ShapedRun(font);
            runs.push(run);
        }

        var upem = font.unitsPerEm;
        var scale = fontSize / upem;
        var single = singlePrecision;
        var pen = 0;
        for (i in 0...buf.length) {
            var ax:Int;
            var ay:Int;
            var base = buf.attachTo[i];
            if (base >= 0 && base < i) {
                ax = absX[base] + buf.xOffset[i];
                ay = absY[base] + buf.yOffset[i];
            }
            else {
                ax = pen + buf.xOffset[i];
                ay = buf.yOffset[i];
            }
            if (i < absX.length) {
                absX[i] = ax;
                absY[i] = ay;
            }
            else {
                absX.push(ax);
                absY.push(ay);
            }
            var advance = buf.xAdvance[i];
            var glyph:ShapedGlyph;
            if (single) {
                // cosmic-text: offsets in ems (f32), times the font size (f32)
                var xOffset = f32(fontSize * f32((ax - pen) / upem));
                var yOffset = f32(fontSize * f32(ay / upem));
                glyph = new ShapedGlyph(buf.glyphs[i], f32(penX + xOffset), f32(0.0 - yOffset), buf.clusters[i]);
                penX = f32(penX + f32(fontSize * f32(advance / upem)));
            }
            else {
                glyph = new ShapedGlyph(buf.glyphs[i], penX + ax * scale, -ay * scale, buf.clusters[i]);
            }
            glyph.advanceUnits = advance;
            glyph.xOffsetUnits = ax - pen;
            glyph.yOffsetUnits = ay;
            run.glyphs.push(glyph);
            pen += advance;
        }

        var m = font.metrics;
        var ascent:Float;
        var descent:Float;
        if (single) {
            ascent = f32(fontSize * f32(m.ascent / upem));
            descent = f32(fontSize * f32(-m.descent / upem));
        }
        else {
            ascent = m.ascent * scale;
            descent = -m.descent * scale;
        }
        if (ascent > layout.ascent) layout.ascent = ascent;
        if (descent > layout.descent) layout.descent = descent;

        return single ? penX : penX + pen * scale;

    }

    /**
     * Rounds a value to the nearest `f32`. An operation on `f32` values
     * computed in double precision then rounded gives the exact `f32`
     * result for `+ - * /` (and a fused multiply-add with a zero addend).
     */
    #if (cpp || js || hl) inline #end
    public static function f32(value:Float):Float {
        #if js
        return js.Syntax.code('Math.fround({0})', value);
        #elseif cpp
        return untyped __cpp__('((double)(float)({0}))', value);
        #elseif hl
        final single:hl.F32 = value;
        return single;
        #else
        return haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(value));
        #end
    }

}
