// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

/**
 * An axis aligned box in font units (y axis pointing up).
 * An empty glyph (like a space) has all values set to 0.
 */
class GlyphBox {

    public var xMin:Float = 0;

    public var yMin:Float = 0;

    public var xMax:Float = 0;

    public var yMax:Float = 0;

    public inline function new() {}

    public inline function set(xMin:Float, yMin:Float, xMax:Float, yMax:Float):GlyphBox {
        this.xMin = xMin;
        this.yMin = yMin;
        this.xMax = xMax;
        this.yMax = yMax;
        return this;
    }

    public inline function isEmpty():Bool {
        return xMax <= xMin || yMax <= yMin;
    }

    public function toString():String {
        return 'GlyphBox($xMin, $yMin, $xMax, $yMax)';
    }

}
