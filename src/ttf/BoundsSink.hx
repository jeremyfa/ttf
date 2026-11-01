// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

/**
 * Computes the control box of an outline: the bounds of every point,
 * control points included (like FreeType's `FT_Outline_Get_CBox` and the
 * bounds stored in `glyf` headers).
 */
class BoundsSink implements OutlineSink {

    public var xMin:Float = 0;

    public var yMin:Float = 0;

    public var xMax:Float = 0;

    public var yMax:Float = 0;

    public var empty:Bool = true;

    public function new() {}

    public inline function reset():Void {
        empty = true;
        xMin = yMin = xMax = yMax = 0;
    }

    inline function add(x:Float, y:Float):Void {
        if (empty) {
            xMin = xMax = x;
            yMin = yMax = y;
            empty = false;
        }
        else {
            if (x < xMin) xMin = x;
            if (x > xMax) xMax = x;
            if (y < yMin) yMin = y;
            if (y > yMax) yMax = y;
        }
    }

    public function moveTo(x:Float, y:Float):Void {
        add(x, y);
    }

    public function lineTo(x:Float, y:Float):Void {
        add(x, y);
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        add(cx, cy);
        add(x, y);
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        add(c1x, c1y);
        add(c2x, c2y);
        add(x, y);
    }

    public function close():Void {}

}
