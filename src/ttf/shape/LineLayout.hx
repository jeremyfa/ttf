// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.shape;

/**
 * A shaped line of text, shaped like GPUI's `LineLayout`: positions are in
 * pixels for `fontSize`, x grows to the right from the start of the line
 * and y grows downward from the baseline. Indices are UTF-8 byte offsets.
 */
class LineLayout {

    public var fontSize:Float = 0;

    /** Total advance of the line, in pixels. */
    public var width:Float = 0;

    /** Largest ascent of the fonts used by the line, in pixels (positive). */
    public var ascent:Float = 0;

    /** Largest descent of the fonts used by the line, in pixels (positive). */
    public var descent:Float = 0;

    public var runs:Array<ShapedRun> = [];

    /** Length of the line in UTF-8 bytes. */
    public var len:Int = 0;

    public function new() {}

    /** Total number of glyphs. */
    public function glyphCount():Int {
        var n = 0;
        for (run in runs)
            n += run.glyphs.length;
        return n;
    }

}

/**
 * Consecutive glyphs using the same font.
 */
class ShapedRun {

    public var font:ttf.Font;

    public var glyphs:Array<ShapedGlyph> = [];

    public function new(font:ttf.Font) {
        this.font = font;
    }

}

/**
 * A positioned glyph.
 */
class ShapedGlyph {

    /** Glyph id in the run's font. */
    public var id:Int;

    /** Position of the glyph origin (pen position plus offsets), in pixels. */
    public var x:Float;

    public var y:Float;

    /** UTF-8 byte offset of the first character of the glyph's cluster. */
    public var index:Int;

    /** Always false for now (color fonts are not supported). */
    public var isEmoji:Bool = false;

    /** Advance of the glyph after shaping, in font units (HarfBuzz `x_advance`). */
    public var advanceUnits:Int = 0;

    /**
     * Offsets of the glyph from the pen position, in font units, y up
     * (HarfBuzz `x_offset` and `y_offset`, attachment of marks included).
     */
    public var xOffsetUnits:Int = 0;

    public var yOffsetUnits:Int = 0;

    public inline function new(id:Int, x:Float, y:Float, index:Int) {
        this.id = id;
        this.x = x;
        this.y = y;
        this.index = index;
    }

    public function toString():String {
        return 'ShapedGlyph($id, $x, $y, $index)';
    }

}
