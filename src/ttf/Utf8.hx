// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

/**
 * UTF-8 helpers for Haxe strings.
 *
 * GPUI (and the shaper of this library) index text with UTF-8 byte
 * offsets, while Haxe strings are indexed by UTF-16 code units on JS and
 * hxcpp. These helpers walk a string by code point (surrogate pairs are
 * combined, lone surrogates become U+FFFD) and convert between both kinds
 * of indices.
 *
 * Iteration is done at the code point level. Grapheme clusters (extended
 * grapheme clusters of UAX #29) are not computed yet: the shaper keeps
 * combining marks, variation selectors and joiners with the previous
 * character, which covers Latin, Greek and Cyrillic text.
 */
class Utf8 {

    /** Number of UTF-8 bytes used to encode a code point. */
    public static inline function codePointLength(c:Int):Int {
        return c < 0x80 ? 1 : (c < 0x800 ? 2 : (c < 0x10000 ? 3 : 4));
    }

    /**
     * Code point at UTF-16 index `index` (combining a surrogate pair).
     */
    public static inline function codePointAt(s:String, index:Int):Int {
        var c = StringTools.fastCodeAt(s, index);
        if (c >= 0xD800 && c <= 0xDBFF) {
            var c2 = index + 1 < s.length ? StringTools.fastCodeAt(s, index + 1) : 0;
            if (c2 >= 0xDC00 && c2 <= 0xDFFF)
                return 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
            return 0xFFFD;
        }
        if (c >= 0xDC00 && c <= 0xDFFF)
            return 0xFFFD;
        return c;
    }

    /** Number of UTF-16 code units used by a code point. */
    public static inline function utf16Length(c:Int):Int {
        return c >= 0x10000 ? 2 : 1;
    }

    /** Length of a string in UTF-8 bytes. */
    public static function byteLength(s:String):Int {
        var n = 0;
        var i = 0;
        var len = s.length;
        while (i < len) {
            var c = StringTools.fastCodeAt(s, i);
            if (c < 0x80) {
                n++;
                i++;
            }
            else {
                var cp = codePointAt(s, i);
                n += codePointLength(cp);
                i += (c >= 0xD800 && c <= 0xDBFF && cp != 0xFFFD) ? 2 : 1;
            }
        }
        return n;
    }

    /**
     * Decodes a string into code points and the UTF-8 byte offset of each
     * code point. Arrays are reused (only grown). Returns the number of
     * code points.
     */
    public static function decode(s:String, codePoints:Array<Int>, byteOffsets:Array<Int>):Int {
        var count = 0;
        var offset = 0;
        var i = 0;
        var len = s.length;
        while (i < len) {
            var c = StringTools.fastCodeAt(s, i);
            var units = 1;
            if (c >= 0x80) {
                var cp = codePointAt(s, i);
                if (c >= 0xD800 && c <= 0xDBFF && cp != 0xFFFD)
                    units = 2;
                c = cp;
            }
            if (count < codePoints.length) {
                codePoints[count] = c;
                byteOffsets[count] = offset;
            }
            else {
                codePoints.push(c);
                byteOffsets.push(offset);
            }
            count++;
            offset += codePointLength(c);
            i += units;
        }
        return count;
    }

    /**
     * Converts a UTF-8 byte offset into a UTF-16 index of `s`. Offsets in
     * the middle of a code point are rounded down to its start.
     */
    public static function byteOffsetToIndex(s:String, byteOffset:Int):Int {
        var offset = 0;
        var i = 0;
        var len = s.length;
        while (i < len) {
            var cp = codePointAt(s, i);
            var n = codePointLength(cp);
            if (offset + n > byteOffset)
                return i;
            offset += n;
            i += (cp >= 0x10000) ? 2 : 1;
        }
        return len;
    }

    /**
     * Converts a UTF-16 index of `s` into a UTF-8 byte offset.
     */
    public static function indexToByteOffset(s:String, index:Int):Int {
        var offset = 0;
        var i = 0;
        while (i < index && i < s.length) {
            var cp = codePointAt(s, i);
            offset += codePointLength(cp);
            i += (cp >= 0x10000) ? 2 : 1;
        }
        return offset;
    }

    /**
     * True for characters that continue the previous one: combining marks,
     * variation selectors, zero width joiners and emoji modifiers.
     */
    public static function isContinuation(c:Int):Bool {
        return (c >= 0x0300 && c <= 0x036F)
            || (c >= 0x1AB0 && c <= 0x1AFF)
            || (c >= 0x1DC0 && c <= 0x1DFF)
            || (c >= 0x20D0 && c <= 0x20FF)
            || (c >= 0xFE20 && c <= 0xFE2F)
            || (c >= 0xFE00 && c <= 0xFE0F)
            || (c >= 0xE0100 && c <= 0xE01EF)
            || c == 0x200D
            || (c >= 0x1F3FB && c <= 0x1F3FF)
            || (c >= 0x0483 && c <= 0x0489);
    }

    /** True for combining marks (general category Mn, common blocks only). */
    public static function isMark(c:Int):Bool {
        return (c >= 0x0300 && c <= 0x036F)
            || (c >= 0x0483 && c <= 0x0489)
            || (c >= 0x1AB0 && c <= 0x1AFF)
            || (c >= 0x1DC0 && c <= 0x1DFF)
            || (c >= 0x20D0 && c <= 0x20FF)
            || (c >= 0xFE20 && c <= 0xFE2F);
    }

    /** True for variation selectors (VS1 to VS256). */
    public static inline function isVariationSelector(c:Int):Bool {
        return (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0xE0100 && c <= 0xE01EF);
    }

    /**
     * True for default ignorable characters that are not rendered when the
     * font has no glyph for them (joiners, directional marks, BOM...).
     */
    public static function isDefaultIgnorable(c:Int):Bool {
        return c == 0x00AD || c == 0x034F || c == 0x061C
            || (c >= 0x115F && c <= 0x1160)
            || (c >= 0x17B4 && c <= 0x17B5)
            || (c >= 0x180B && c <= 0x180F)
            || (c >= 0x200B && c <= 0x200F)
            || (c >= 0x202A && c <= 0x202E)
            || (c >= 0x2060 && c <= 0x206F)
            || c == 0x3164
            || (c >= 0xFE00 && c <= 0xFE0F)
            || c == 0xFEFF
            || c == 0xFFA0
            || (c >= 0xFFF0 && c <= 0xFFF8)
            || (c >= 0x1BCA0 && c <= 0x1BCA3)
            || (c >= 0x1D173 && c <= 0x1D17A)
            || (c >= 0xE0000 && c <= 0xE0FFF);
    }

}
