// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.color;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * `COLR` version 0 (a color glyph is a stack of outline glyphs, each one
 * filled with a palette color) and `CPAL` (the palettes), used by Segoe UI
 * Emoji on Windows and by the COLR builds of Noto Color Emoji and Twemoji.
 *
 * Version 1 paint graphs (gradients, transforms, composite modes) are not
 * supported; a version 1 table still gives its version 0 glyphs.
 */
class Colr {

    final data:Bytes;

    final colr:Int;

    final numBaseGlyphs:Int;

    final baseGlyphs:Int;

    final layers:Int;

    final numLayers:Int;

    /** Colors of the palettes, `[r, g, b, a]` per entry */
    final cpal:Int;

    final numPaletteEntries:Int;

    final numPalettes:Int;

    final colorRecords:Int;

    final numColorRecords:Int;

    public function new(font:Font) {
        data = font.data;
        colr = font.table('COLR');
        if (colr >= 0 && font.tableLength('COLR') >= 14) {
            numBaseGlyphs = u16(data, colr + 2);
            baseGlyphs = colr + u32(data, colr + 4);
            layers = colr + u32(data, colr + 8);
            numLayers = u16(data, colr + 12);
        }
        else {
            numBaseGlyphs = 0;
            baseGlyphs = 0;
            layers = 0;
            numLayers = 0;
        }
        cpal = font.table('CPAL');
        if (cpal >= 0 && font.tableLength('CPAL') >= 12) {
            numPaletteEntries = u16(data, cpal + 2);
            numPalettes = u16(data, cpal + 4);
            numColorRecords = u16(data, cpal + 6);
            colorRecords = cpal + u32(data, cpal + 8);
        }
        else {
            numPaletteEntries = 0;
            numPalettes = 0;
            numColorRecords = 0;
            colorRecords = 0;
        }
    }

    /** True if the table has layers for the glyph */
    public inline function hasGlyph(gid:Int):Bool {
        return find(gid) >= 0;
    }

    /** Offset of the base glyph record of a glyph, or -1 (binary search) */
    function find(gid:Int):Int {
        var lo = 0;
        var hi = numBaseGlyphs;
        while (lo < hi) {
            var mid = (lo + hi) >> 1;
            var rec = baseGlyphs + mid * 6;
            var id = u16(data, rec);
            if (gid < id)
                hi = mid;
            else if (gid > id)
                lo = mid + 1;
            else
                return rec;
        }
        return -1;
    }

    /** Number of layers of a glyph (0 if it is not a color glyph) */
    public function layerCount(gid:Int):Int {
        var rec = find(gid);
        if (rec < 0)
            return 0;
        var first = u16(data, rec + 2);
        var count = u16(data, rec + 4);
        if (first + count > numLayers)
            return 0;
        return count;
    }

    /** Glyph id of a layer of a glyph (bottom layer first) */
    public function layerGlyph(gid:Int, layer:Int):Int {
        var rec = find(gid);
        return u16(data, layers + (u16(data, rec + 2) + layer) * 4);
    }

    /** Palette entry of a layer of a glyph (0xFFFF: the text color) */
    public function layerPaletteIndex(gid:Int, layer:Int):Int {
        var rec = find(gid);
        return u16(data, layers + (u16(data, rec + 2) + layer) * 4 + 2);
    }

    /**
     * Color of a palette entry as `0xAARRGGBB`, or -1 if the palette or
     * the entry does not exist.
     */
    public function paletteColor(palette:Int, entry:Int):Int {
        if (palette < 0 || palette >= numPalettes || entry < 0 || entry >= numPaletteEntries)
            return -1;
        var first = u16(data, cpal + 12 + palette * 2);
        var index = first + entry;
        if (index >= numColorRecords)
            return -1;
        // Color records are BGRA
        var p = colorRecords + index * 4;
        return (data.get(p + 3) << 24) | (data.get(p + 2) << 16) | (data.get(p + 1) << 8) | data.get(p);
    }

}
