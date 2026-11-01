// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Character to glyph mapping (`cmap` table).
 *
 * Supported subtable formats: 0, 4, 6, 10, 12 and 13 for the main mapping,
 * and 14 for Unicode variation sequences. The best Unicode subtable is
 * picked once when the font is loaded (full repertoire first, then BMP,
 * then symbol, then Macintosh Roman).
 */
class Cmap {

    var data:Bytes;

    /** Absolute offset of the selected subtable, or -1. */
    var sub:Int = -1;

    var format:Int = -1;

    /** Absolute offset of the format 14 subtable, or -1. */
    var uvs:Int = -1;

    /** Format 3.0 (symbol) fonts map U+F000 + byte as well. */
    var symbol:Bool = false;

    // Format 4 cache
    var segCountX2:Int = 0;
    var endCodes:Int = 0;

    // Small direct cache for the first 256 code points (most text is ASCII)
    var asciiCache:haxe.ds.Vector<Int>;

    public function new(data:Bytes, offset:Int, length:Int) {

        this.data = data;

        if (offset < 0)
            return;

        var numTables = u16(data, offset + 2);
        var bestScore = -1;
        for (i in 0...numTables) {
            var rec = offset + 4 + i * 8;
            var platformId = u16(data, rec);
            var encodingId = u16(data, rec + 2);
            var subOffset = offset + u32(data, rec + 4);
            var subFormat = u16(data, subOffset);
            if (subFormat == 14) {
                if (platformId == 0 && encodingId == 5)
                    uvs = subOffset;
                continue;
            }
            var score = -1;
            if (platformId == 3 && encodingId == 10) score = 10;
            else if (platformId == 0 && (encodingId == 4 || encodingId == 6)) score = 9;
            else if (platformId == 3 && encodingId == 1) score = 8;
            else if (platformId == 0 && encodingId <= 3) score = 7;
            else if (platformId == 3 && encodingId == 0) score = 5;
            else if (platformId == 1 && encodingId == 0) score = 1;
            if (score < 0)
                continue;
            switch subFormat {
                case 0 | 4 | 6 | 10 | 12 | 13:
                default: continue;
            }
            if (score > bestScore) {
                bestScore = score;
                sub = subOffset;
                format = subFormat;
                symbol = (platformId == 3 && encodingId == 0);
            }
        }

        if (format == 4) {
            segCountX2 = u16(data, sub + 6);
            endCodes = sub + 14;
        }

        asciiCache = new haxe.ds.Vector(256);
        for (c in 0...256)
            asciiCache[c] = -1;

    }

    /**
     * Returns the glyph id for the given code point, or 0 (`.notdef`).
     */
    public function glyphId(codePoint:Int):Int {

        if (codePoint >= 0 && codePoint < 256) {
            var cached = asciiCache[codePoint];
            if (cached >= 0)
                return cached;
            var gid = lookup(codePoint);
            if (gid == 0 && symbol)
                gid = lookup(0xF000 + codePoint);
            asciiCache[codePoint] = gid;
            return gid;
        }

        var gid = lookup(codePoint);
        return gid;

    }

    /**
     * Returns the glyph id of a variation sequence (base code point followed
     * by a variation selector), using the format 14 subtable.
     * Falls back to the default mapping of `codePoint` when the sequence
     * uses the default glyph or is not listed. Returns -1 if there is
     * no format 14 subtable.
     */
    public function variantGlyphId(codePoint:Int, selector:Int):Int {

        if (uvs < 0)
            return -1;

        var b = data;
        var count = u32(b, uvs + 6);
        // Variation selector records are sorted by selector
        var lo = 0;
        var hi = count - 1;
        var rec = -1;
        while (lo <= hi) {
            var mid = (lo + hi) >> 1;
            var r = uvs + 10 + mid * 11;
            var vs = u24(b, r);
            if (vs < selector) lo = mid + 1;
            else if (vs > selector) hi = mid - 1;
            else { rec = r; break; }
        }
        if (rec < 0)
            return glyphId(codePoint);

        var defaultOffset = u32(b, rec + 3);
        var nonDefaultOffset = u32(b, rec + 7);

        if (nonDefaultOffset != 0) {
            var t = uvs + nonDefaultOffset;
            var n = u32(b, t);
            var lo = 0;
            var hi = n - 1;
            while (lo <= hi) {
                var mid = (lo + hi) >> 1;
                var m = t + 4 + mid * 5;
                var u = u24(b, m);
                if (u < codePoint) lo = mid + 1;
                else if (u > codePoint) hi = mid - 1;
                else return u16(b, m + 3);
            }
        }

        // Default UVS table, or not listed: use the regular mapping
        return glyphId(codePoint);

    }

    function lookup(c:Int):Int {

        var b = data;
        var s = sub;
        if (s < 0)
            return 0;

        switch format {

            case 4:
                if (c > 0xFFFF)
                    return 0;
                // Binary search on end codes
                var segCount = segCountX2 >> 1;
                var lo = 0;
                var hi = segCount - 1;
                var seg = -1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var end = u16(b, endCodes + mid * 2);
                    if (end < c) lo = mid + 1;
                    else {
                        seg = mid;
                        hi = mid - 1;
                    }
                }
                if (seg < 0)
                    return 0;
                var startCodes = endCodes + segCountX2 + 2;
                var start = u16(b, startCodes + seg * 2);
                if (c < start)
                    return 0;
                var idDeltas = startCodes + segCountX2;
                var idRangeOffsets = idDeltas + segCountX2;
                var delta = u16(b, idDeltas + seg * 2);
                var rangeOffsetPos = idRangeOffsets + seg * 2;
                var rangeOffset = u16(b, rangeOffsetPos);
                if (rangeOffset == 0)
                    return (c + delta) & 0xFFFF;
                var glyphPos = rangeOffsetPos + rangeOffset + (c - start) * 2;
                if (glyphPos + 1 >= b.length)
                    return 0;
                var g = u16(b, glyphPos);
                if (g == 0)
                    return 0;
                return (g + delta) & 0xFFFF;

            case 12 | 13:
                var nGroups = u32(b, s + 12);
                var lo = 0;
                var hi = nGroups - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var g = s + 16 + mid * 12;
                    var startChar = u32(b, g);
                    var endChar = u32(b, g + 4);
                    if (c < startChar) hi = mid - 1;
                    else if (c > endChar) lo = mid + 1;
                    else {
                        var startGlyph = u32(b, g + 8);
                        return format == 12 ? startGlyph + (c - startChar) : startGlyph;
                    }
                }
                return 0;

            case 0:
                if (c < 0 || c > 255)
                    return 0;
                return b.get(s + 6 + c);

            case 6:
                var first = u16(b, s + 6);
                var count = u16(b, s + 8);
                if (c < first || c >= first + count)
                    return 0;
                return u16(b, s + 10 + (c - first) * 2);

            case 10:
                var first = u32(b, s + 12);
                var count = u32(b, s + 16);
                if (c < first || c >= first + count)
                    return 0;
                return u16(b, s + 20 + (c - first) * 2);

            default:
                return 0;
        }

    }

}
