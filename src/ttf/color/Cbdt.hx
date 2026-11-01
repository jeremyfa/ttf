// Ported from swash 0.2.10: src/strike.rs (CBLC strikes, get_coverage, get_location, get_data, Bitmap::new)
// Original code Copyright 2020 Chad Brokaw, licensed under MIT / Apache-2.0.
// Modified: translated from Rust to Haxe, part of the ttf library for Ceramic.
// PNG image formats only (17, 18, 19: the ones color fonts use); the binary
// search of index format 4 steps to `i + 1` (swash has `i + i`).
package ttf.color;

import ttf.Bin.*;

/**
 * Google's color bitmap tables, `CBLC` (strikes and glyph locations) and
 * `CBDT` (PNG images), used by Noto Color Emoji on Linux and Android.
 *
 * `CBLC` is small and read whole with the font; `CBDT` images are read
 * through `Font.readTable()`, so the table can stay in the font file
 * (`Font.fromSource()`).
 */
class Cbdt {

    final font:Font;

    final range = new TableRange();

    /** Absolute offset of `CBLC` in `font.data` */
    final cblc:Int;

    final data:haxe.io.Bytes;

    public final strikeCount:Int;

    public function new(font:Font) {
        this.font = font;
        data = font.data;
        cblc = font.table('CBLC');
        strikeCount = cblc >= 0 ? u32(data, cblc + 4) : 0;
    }

    inline function strikeBase(strike:Int):Int {
        return cblc + 8 + strike * 48;
    }

    /** Pixels per em of a strike */
    public function strikePpem(strike:Int):Int {
        return data.get(strikeBase(strike) + 45);
    }

    /** True if the strike has the glyph (swash `get_coverage`) */
    public function contains(strike:Int, gid:Int):Bool {
        var base = strikeBase(strike);
        if (gid < u16(data, base + 40) || gid > u16(data, base + 42))
            return false;
        var count = u32(data, base + 8);
        var array = cblc + u32(data, base);
        for (i in 0...count) {
            var rec = array + i * 8;
            if (gid < u16(data, rec))
                return false;
            if (gid > u16(data, rec + 2))
                continue;
            return true;
        }
        return false;
    }

    /** Same rule as `Sbix.findStrike()` */
    public function findStrike(ppem:Int, gid:Int):Int {
        var best = -1;
        var bestSize = 0;
        for (i in 0...strikeCount) {
            if (!contains(i, gid))
                continue;
            best = i;
            var size = strikePpem(i);
            if (size > bestSize) {
                best = i;
                bestSize = size;
            }
            if (size >= ppem)
                return i;
        }
        return best;
    }

    /**
     * Fills `out` with the PNG image of a glyph in a strike. Returns false
     * if the strike has no PNG image for it.
     */
    public function glyph(strike:Int, gid:Int, out:BitmapGlyph):Bool {
        var base = strikeBase(strike);
        if (gid < u16(data, base + 40) || gid > u16(data, base + 42))
            return false;
        var count = u32(data, base + 8);
        var ppem = data.get(base + 45);
        var array = cblc + u32(data, base);
        for (i in 0...count) {
            var rec = array + i * 8;
            var first = u16(data, rec);
            if (gid < first)
                return false;
            if (gid > u16(data, rec + 2))
                continue;
            var sub = array + u32(data, rec + 4);
            var indexFormat = u16(data, sub);
            var imageFormat = u16(data, sub + 2);
            var imageOffset = u32(data, sub + 4);
            var b = sub + 8;
            var offset = -1;
            var size = -1;
            // Metrics from the index (format 2 and 5), used by image format 19
            var metricsPos = -1;
            switch indexFormat {
                case 1:
                    var o1 = u32(data, b + (gid - first) * 4);
                    var o2 = u32(data, b + (gid - first + 1) * 4);
                    offset = imageOffset + o1;
                    size = o2 - o1;
                case 2:
                    size = u32(data, b);
                    offset = imageOffset + size * (gid - first);
                    metricsPos = b + 4;
                case 3:
                    var o1 = u16(data, b + (gid - first) * 2);
                    var o2 = u16(data, b + (gid - first + 1) * 2);
                    offset = imageOffset + o1;
                    size = o2 - o1;
                case 4:
                    var lo = 0;
                    var hi = u32(data, b);
                    while (lo < hi) {
                        var mid = (lo + hi) >> 1;
                        var r = b + 4 + mid * 4;
                        var id = u16(data, r);
                        if (gid < id) {
                            hi = mid;
                        }
                        else if (gid > id) {
                            lo = mid + 1;
                        }
                        else {
                            var o1 = u16(data, r + 2);
                            var o2 = u16(data, r + 6);
                            if (o2 <= o1)
                                return false;
                            offset = imageOffset + o1;
                            size = o2 - o1;
                            break;
                        }
                    }
                case 5:
                    size = u32(data, b);
                    metricsPos = b + 4;
                    var numGlyphs = u32(data, b + 12);
                    var ids = b + 16;
                    var found = -1;
                    var lo = 0;
                    var hi = numGlyphs;
                    while (lo < hi) {
                        var mid = (lo + hi) >> 1;
                        var id = u16(data, ids + mid * 2);
                        if (gid < id) hi = mid;
                        else if (gid > id) lo = mid + 1;
                        else {
                            found = mid;
                            break;
                        }
                    }
                    if (found < 0)
                        return false;
                    offset = imageOffset + size * found;
                case _:
                    return false;
            }
            if (offset < 0 || size <= 0)
                return false;
            if (!font.readTable('CBDT', offset, size, range))
                return false;
            var bytes = range.bytes;
            var p = range.pos;
            var pngPos = -1;
            var pngLen = 0;
            var x = 0;
            var y = 0;
            switch imageFormat {
                case 17:
                    // smallGlyphMetrics (5 bytes), length, PNG
                    if (size < 9) return false;
                    x = s8(bytes, p + 2);
                    y = s8(bytes, p + 3);
                    pngLen = u32(bytes, p + 5);
                    pngPos = p + 9;
                case 18:
                    // bigGlyphMetrics (8 bytes), length, PNG
                    if (size < 12) return false;
                    x = s8(bytes, p + 2);
                    y = s8(bytes, p + 3);
                    pngLen = u32(bytes, p + 8);
                    pngPos = p + 12;
                case 19:
                    if (size < 4 || metricsPos < 0) return false;
                    x = s8(data, metricsPos + 2);
                    y = s8(data, metricsPos + 3);
                    pngLen = u32(bytes, p);
                    pngPos = p + 4;
                case _:
                    return false;
            }
            if (pngPos + pngLen > p + size)
                return false;
            var width = Png.headerWidth(bytes, pngPos, pngLen);
            var height = Png.headerHeight(bytes, pngPos, pngLen);
            if (width <= 0 || height <= 0)
                return false;
            out.bytes = bytes;
            out.pos = pngPos;
            out.length = pngLen;
            out.ppem = ppem;
            out.width = width;
            out.height = height;
            out.left = x;
            out.top = y;
            out.flip = false;
            return true;
        }
        return false;
    }

}
