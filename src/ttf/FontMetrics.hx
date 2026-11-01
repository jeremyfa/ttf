// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

/**
 * Global font metrics, in font units (y axis pointing up).
 *
 * The fields follow GPUI's `FontMetrics`: `descent` is negative (below the
 * baseline) and `underlinePosition` is usually negative too.
 *
 * Ascent, descent and line gap follow HarfBuzz: `OS/2` typographic values
 * when the font sets `USE_TYPO_METRICS`, `hhea` values otherwise (and
 * `OS/2` typographic, then Windows values when `hhea` is empty).
 */
class FontMetrics {

    public var unitsPerEm:Int = 1000;

    public var ascent:Float = 0;

    public var descent:Float = 0;

    public var lineGap:Float = 0;

    public var underlinePosition:Float = 0;

    public var underlineThickness:Float = 0;

    public var capHeight:Float = 0;

    public var xHeight:Float = 0;

    /** Bounds of every glyph (`head` table `xMin`, `yMin`, `xMax`, `yMax`). */
    public var xMin:Float = 0;

    public var yMin:Float = 0;

    public var xMax:Float = 0;

    public var yMax:Float = 0;

    public function new() {}

    /** Converts a value in font units into pixels for the given font size. */
    public inline function scale(value:Float, fontSize:Float):Float {
        return value * fontSize / unitsPerEm;
    }

    public function toString():String {
        return 'FontMetrics(unitsPerEm=$unitsPerEm ascent=$ascent descent=$descent lineGap=$lineGap underlinePosition=$underlinePosition underlineThickness=$underlineThickness capHeight=$capHeight xHeight=$xHeight bbox=$xMin,$yMin,$xMax,$yMax)';
    }

}
