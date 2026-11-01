// Ported from swash 0.2.10: src/strike.rs (sbix strikes, find_by_nearest_ppem, sbix_range, Bitmap::new)
// Original code Copyright 2020 Chad Brokaw, licensed under MIT / Apache-2.0.
// Modified: translated from Rust to Haxe, part of the ttf library for Ceramic.
// Reads the table through `Font.readTable()` (it can stay in the font file),
// keeps the origin offsets as 16-bit values (swash truncates them to 8 bits)
// and supports Apple's `flip` glyphs (a mirrored copy of another glyph).
package ttf.color;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Apple's `sbix` table: PNG images of the glyphs at several sizes (Apple
 * Color Emoji has strikes of 20, 26, 32, 40, 48, 52, 64, 96 and 160 pixels
 * per em).
 *
 * The strike header and the glyph offsets of a strike are read once; glyph
 * images are read when asked for, so a font loaded with
 * `Font.fromSource()` only reads the images it draws.
 */
class Sbix {

    final font:Font;

    final range = new TableRange();

    final numGlyphs:Int;

    /** Offsets of the strikes in the table */
    final strikeOffsets:Array<Int> = [];

    /** Pixels per em of each strike */
    public final strikePpem:Array<Int> = [];

    /** Glyph data offsets of each strike (`numGlyphs + 1` values), read when needed */
    final glyphOffsets:Array<Null<Bytes>> = [];

    /**
     * True for Apple Color Emoji, whose images sit 100 font units lower than
     * their origin offsets say (swash's adjustment, close to CoreText's
     * placement).
     */
    public final isApple:Bool;

    final upem:Int;

    public function new(font:Font) {
        this.font = font;
        numGlyphs = font.numGlyphs;
        upem = font.unitsPerEm;
        isApple = font.familyName == 'Apple Color Emoji';
        if (!font.readTable('sbix', 0, 8, range))
            return;
        var count = u32(range.bytes, range.pos + 4);
        if (count <= 0 || count > 1024 || !font.readTable('sbix', 8, count * 4, range))
            return;
        var offsets = [for (i in 0...count) u32(range.bytes, range.pos + i * 4)];
        for (offset in offsets) {
            if (!font.readTable('sbix', offset, 4, range))
                continue;
            strikeOffsets.push(offset);
            strikePpem.push(u16(range.bytes, range.pos));
            glyphOffsets.push(null);
        }
    }

    public var strikeCount(get, never):Int;

    inline function get_strikeCount():Int {
        return strikeOffsets.length;
    }

    function offsetsOf(strike:Int):Null<Bytes> {
        var offsets = glyphOffsets[strike];
        if (offsets == null) {
            if (!font.readTable('sbix', strikeOffsets[strike] + 4, (numGlyphs + 1) * 4, range))
                return null;
            offsets = range.bytes.sub(range.pos, (numGlyphs + 1) * 4);
            glyphOffsets[strike] = offsets;
        }
        return offsets;
    }

    static inline final PNG = 0x706E6720; // 'png '
    static inline final DUPE = 0x64757065; // 'dupe'
    static inline final FLIP = 0x666C6970; // 'flip'

    /**
     * Fills `out` with the PNG image of a glyph in a strike, resolving
     * `dupe` and `flip` references (one level, like swash). Returns false if
     * the strike has no image for the glyph.
     */
    public function glyph(strike:Int, gid:Int, out:BitmapGlyph):Bool {
        return resolve(strike, gid, out, 0, false);
    }

    function resolve(strike:Int, gid:Int, out:BitmapGlyph, recurse:Int, flip:Bool):Bool {
        if (recurse > 1 || gid < 0 || gid >= numGlyphs || strike < 0 || strike >= strikeOffsets.length)
            return false;
        var offsets = offsetsOf(strike);
        if (offsets == null)
            return false;
        var start = u32(offsets, gid * 4);
        var end = u32(offsets, gid * 4 + 4);
        if (end <= start || end - start < 8)
            return false;
        var base = strikeOffsets[strike];
        if (!font.readTable('sbix', base + start, end - start, range))
            return false;
        var bytes = range.bytes;
        var p = range.pos;
        var tag = u32(bytes, p + 4);
        if (tag == DUPE || tag == FLIP) {
            if (end - start < 10)
                return false;
            return resolve(strike, u16(bytes, p + 8), out, recurse + 1, flip || tag == FLIP);
        }
        if (tag != PNG)
            return false;
        var len = end - start - 8;
        var width = Png.headerWidth(bytes, p + 8, len);
        var height = Png.headerHeight(bytes, p + 8, len);
        if (width <= 0 || height <= 0)
            return false;
        out.bytes = bytes;
        out.pos = p + 8;
        out.length = len;
        out.ppem = strikePpem[strike];
        out.width = width;
        out.height = height;
        out.flip = flip;
        out.left = s16(bytes, p);
        var top = s16(bytes, p + 2);
        if (top == 0 && isApple)
            top = roundHalfAway(-100.0 * out.ppem / upem);
        out.top = top + height;
        return true;
    }

    /** True if the strike has an image for the glyph */
    public function contains(strike:Int, gid:Int):Bool {
        if (gid < 0 || gid >= numGlyphs)
            return false;
        var offsets = offsetsOf(strike);
        if (offsets == null)
            return false;
        var start = u32(offsets, gid * 4);
        var end = u32(offsets, gid * 4 + 4);
        if (end <= start || end - start < 8)
            return false;
        if (!font.readTable('sbix', strikeOffsets[strike] + start, 8, range))
            return false;
        var tag = u32(range.bytes, range.pos + 4);
        return tag == PNG || tag == DUPE || tag == FLIP;
    }

    /**
     * The strike for a glyph at `ppem` pixels per em (swash
     * `find_by_nearest_ppem`): the first strike, in table order, at least
     * that large, else the last one with the glyph (the largest one when
     * strikes grow); -1 if no strike has the glyph.
     */
    public function findStrike(ppem:Int, gid:Int):Int {
        var best = -1;
        var bestSize = 0;
        for (i in 0...strikeOffsets.length) {
            if (!contains(i, gid))
                continue;
            best = i;
            var size = strikePpem[i];
            if (size > bestSize) {
                best = i;
                bestSize = size;
            }
            if (size >= ppem)
                return i;
        }
        return best;
    }

    /** Rust `f32::round`: halves away from zero */
    public static inline function roundHalfAway(v:Float):Int {
        return v < 0 ? -Math.round(-v) : Math.round(v);
    }

}
