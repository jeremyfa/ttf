// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

/**
 * Receives glyph outlines, in font units with the y axis pointing up.
 *
 * TrueType (`glyf`) outlines emit quadratic curves, CFF and CFF2 outlines
 * emit cubic curves. Every contour starts with `moveTo()` and ends with
 * `close()`.
 */
interface OutlineSink {

    function moveTo(x:Float, y:Float):Void;

    function lineTo(x:Float, y:Float):Void;

    function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void;

    function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void;

    function close():Void;

}
