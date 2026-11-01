// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import plutovg.Path;

/**
 * Appends glyph outlines to a plutovg `Path`, converting font units into
 * pixels: `x' = x * scale + originX` and `y' = originY - y * scale`
 * (the path uses a y axis pointing down, like the bitmaps it renders to).
 */
class PathOutlineSink implements OutlineSink {

    public var path:Path;

    public var scale:Float = 1;

    public var originX:Float = 0;

    public var originY:Float = 0;

    public function new(?path:Path) {
        this.path = path != null ? path : new Path();
    }

    /**
     * Sets the transform used for the next outlines.
     */
    public inline function setTransform(scale:Float, originX:Float, originY:Float):Void {
        this.scale = scale;
        this.originX = originX;
        this.originY = originY;
    }

    public function moveTo(x:Float, y:Float):Void {
        path.moveTo(x * scale + originX, originY - y * scale);
    }

    public function lineTo(x:Float, y:Float):Void {
        path.lineTo(x * scale + originX, originY - y * scale);
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        path.quadTo(cx * scale + originX, originY - cy * scale, x * scale + originX, originY - y * scale);
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        path.cubicTo(
            c1x * scale + originX, originY - c1y * scale,
            c2x * scale + originX, originY - c2y * scale,
            x * scale + originX, originY - y * scale
        );
    }

    public function close():Void {
        path.close();
    }

}
