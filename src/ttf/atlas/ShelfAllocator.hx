// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.atlas;

/**
 * Shelf packing for glyph atlases: rectangles are placed left to right on
 * horizontal shelves. A rectangle goes on the shelf with the smallest
 * height that fits it (and is not more than twice as tall), otherwise a
 * new shelf is opened. Shelf heights are rounded up to a multiple of 4 so
 * that glyphs of close sizes share shelves.
 *
 * Glyphs of a font at a given size have similar heights, which makes this
 * simple scheme efficient. Rectangles are never freed one by one: a page
 * is reset as a whole (see `GlyphAtlas`).
 */
class ShelfAllocator {

    public var width(default, null):Int;

    public var height(default, null):Int;

    var shelfY:Array<Int> = [];

    var shelfHeight:Array<Int> = [];

    var shelfX:Array<Int> = [];

    var nextY:Int = 0;

    /** Position of the last allocation. */
    public var x(default, null):Int = 0;

    public var y(default, null):Int = 0;

    /** Area used by allocations, for statistics. */
    public var usedArea(default, null):Int = 0;

    public function new(width:Int, height:Int) {
        this.width = width;
        this.height = height;
    }

    public function reset():Void {
        shelfY.resize(0);
        shelfHeight.resize(0);
        shelfX.resize(0);
        nextY = 0;
        usedArea = 0;
    }

    /**
     * Reserves a `w` x `h` rectangle. On success, returns true and the
     * position is available in `x` and `y`.
     */
    public function allocate(w:Int, h:Int):Bool {

        if (w > width || h > height || w <= 0 || h <= 0)
            return false;

        var best = -1;
        var bestHeight = 0x7FFFFFFF;
        for (i in 0...shelfY.length) {
            var sh = shelfHeight[i];
            if (sh >= h && sh <= h * 2 && sh < bestHeight && shelfX[i] + w <= width) {
                best = i;
                bestHeight = sh;
            }
        }

        if (best < 0) {
            var sh = (h + 3) & ~3;
            if (nextY + sh > height)
                sh = h;
            if (nextY + sh > height)
                return false;
            best = shelfY.length;
            shelfY.push(nextY);
            shelfHeight.push(sh);
            shelfX.push(0);
            nextY += sh;
        }

        x = shelfX[best];
        y = shelfY[best];
        shelfX[best] = x + w;
        usedArea += w * h;
        return true;

    }

}
