// Ported from zeno 0.3.3: src/raster.rs (Rasterizer, line_to, quad_to,
// curve_to, split_quad, split_cubic, coverage).
// Original code Copyright (c) 2020 Chad Brokaw, licensed under Apache-2.0 OR
// MIT (used here under MIT). zeno's rasterizer follows the algorithm of
// FreeType's smooth rasterizer (src/smooth/ftgrays.c, The FreeType Project).
// Modified: translated from Rust to Haxe, dense cell storage instead of
// zeno's cell lists (cells are summed, so the coverage is identical).
package ttf;

import haxe.io.Bytes;

/**
 * Anti-aliased scan converter producing 8-bit coverage, bit exact with zeno,
 * the rasterizer of swash (used by GPUI's `CosmicTextSystem`).
 *
 * Coordinates are 24.8 fixed point (`ONE_PIXEL` = 256) inside a
 * `width` x `height` area, y up: row 0 is the bottom row, and `render()`
 * writes it as the last row of the destination (like zeno with
 * `Origin::BottomLeft`). Floats given to `moveTo()` / `lineTo()` /
 * `quadTo()` / `cubicTo()` are pixel coordinates converted like zeno's
 * `to_fixed()` (`v * 256`, truncated toward zero).
 *
 * Only the non-zero fill rule is implemented (zeno's `Fill::NonZero`).
 */
class GrayRaster {

    static inline var PIXEL_BITS = 8;

    static inline var ONE_PIXEL = 1 << PIXEL_BITS;

    var width:Int = 0;

    var height:Int = 0;

    /** Cell storage: `(width + 1) * height`, column 0 is x = -1 */
    var areas:Array<Int> = [];

    var covers:Array<Int> = [];

    var used:Bytes = Bytes.alloc(0);

    var cellX:Int = 0;

    var cellY:Int = 0;

    var cover:Int = 0;

    var area:Int = 0;

    var invalid:Bool = true;

    var px:Int = 0;

    var py:Int = 0;

    var startX:Int = 0;

    var startY:Int = 0;

    var closed:Bool = true;

    /** Subdivision stack (zeno: `16 * 8 + 1` points) */
    var arcX:Array<Int> = [for (_ in 0...(16 * 8 + 1)) 0];

    var arcY:Array<Int> = [for (_ in 0...(16 * 8 + 1)) 0];

    public function new() {}

    /**
     * Starts a new mask of `width` x `height` pixels.
     */
    public function reset(width:Int, height:Int):Void {
        this.width = width;
        this.height = height;
        var n = (width + 1) * height;
        if (used.length < n)
            used = Bytes.alloc(n);
        used.fill(0, n, 0);
        while (areas.length < n) {
            areas.push(0);
            covers.push(0);
        }
        for (i in 0...n) {
            areas[i] = 0;
            covers[i] = 0;
        }
        closed = true;
        invalid = true;
        cellX = 0;
        cellY = 0;
        px = 0;
        py = 0;
        cover = 0;
        area = 0;
        startX = 0;
        startY = 0;
    }

    static inline function toFixed(v:Float):Int {
        return Std.int(v * 256);
    }

    static inline function trunc(x:Int):Int {
        return x >> PIXEL_BITS;
    }

    static inline function fract(x:Int):Int {
        return x & (ONE_PIXEL - 1);
    }

    static inline function abs(x:Int):Int {
        return x < 0 ? -x : x;
    }

    /** `((a as u64 * b as u64) >> 24) as i32` */
    static inline function udiv(a:Int, b:Int):Int {
        return Std.int(Math.floor((a * 1.0) * b / 16777216.0));
    }

/// Path building (zeno's PathBuilder impl for Rasterizer)

    public function moveTo(x:Float, y:Float):Void {
        if (!closed)
            fixedLineTo(startX, startY);
        var fx = toFixed(x);
        var fy = toFixed(y);
        fixedMoveTo(fx, fy);
        closed = false;
        startX = fx;
        startY = fy;
    }

    public function lineTo(x:Float, y:Float):Void {
        closed = false;
        fixedLineTo(toFixed(x), toFixed(y));
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        closed = false;
        fixedQuadTo(toFixed(cx), toFixed(cy), toFixed(x), toFixed(y));
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        closed = false;
        fixedCubicTo(toFixed(c1x), toFixed(c1y), toFixed(c2x), toFixed(c2y), toFixed(x), toFixed(y));
    }

    public function close():Void {
        fixedLineTo(startX, startY);
        closed = true;
    }

/// Cells

    function storeCell(x:Int, y:Int, a:Int, c:Int):Void {
        var i = y * (width + 1) + x + 1;
        areas[i] += a;
        covers[i] += c;
        used.set(i, 1);
    }

    function setCell(x:Int, y:Int):Void {
        if (!invalid && (area != 0 || cover != 0))
            storeCell(cellX, cellY, area, cover);
        area = 0;
        cover = 0;
        cellX = x > -1 ? x : -1;
        cellY = y;
        invalid = y >= height || y < 0 || x >= width;
    }

    function fixedMoveTo(x:Int, y:Int):Void {
        setCell(trunc(x), trunc(y));
        px = x;
        py = y;
    }

    function fixedLineTo(toX:Int, toY:Int):Void {
        var ey1 = trunc(py);
        var ey2 = trunc(toY);
        if ((ey1 >= height && ey2 >= height) || (ey1 < 0 && ey2 < 0)) {
            px = toX;
            py = toY;
            return;
        }
        var ex1 = trunc(px);
        var ex2 = trunc(toX);
        var fx1 = fract(px);
        var fy1 = fract(py);
        var dx = toX - px;
        var dy = toY - py;
        if (ex1 == ex2 && ey1 == ey2) {
            // empty
        }
        else if (dy == 0) {
            setCell(ex2, ey2);
            px = toX;
            py = toY;
            return;
        }
        else if (dx == 0) {
            if (dy > 0) {
                while (true) {
                    var fy2 = ONE_PIXEL;
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * fx1 * 2;
                    fy1 = 0;
                    ey1++;
                    setCell(ex1, ey1);
                    if (ey1 == ey2)
                        break;
                }
            }
            else {
                while (true) {
                    var fy2 = 0;
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * fx1 * 2;
                    fy1 = ONE_PIXEL;
                    ey1--;
                    setCell(ex1, ey1);
                    if (ey1 == ey2)
                        break;
                }
            }
        }
        else {
            var prod = dx * fy1 - dy * fx1;
            var dxR = ex1 != ex2 ? Std.int(0x00FFFFFF / dx) : 0;
            var dyR = ey1 != ey2 ? Std.int(0x00FFFFFF / dy) : 0;
            while (true) {
                if (prod <= 0 && prod - dx * ONE_PIXEL > 0) {
                    var fx2 = 0;
                    var fy2 = udiv(-prod, -dxR);
                    prod -= dy * ONE_PIXEL;
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * (fx1 + fx2);
                    fx1 = ONE_PIXEL;
                    fy1 = fy2;
                    ex1--;
                }
                else if (prod - dx * ONE_PIXEL <= 0 && prod - dx * ONE_PIXEL + dy * ONE_PIXEL > 0) {
                    prod -= dx * ONE_PIXEL;
                    var fx2 = udiv(-prod, dyR);
                    var fy2 = ONE_PIXEL;
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * (fx1 + fx2);
                    fx1 = fx2;
                    fy1 = 0;
                    ey1++;
                }
                else if (prod - dx * ONE_PIXEL + dy * ONE_PIXEL <= 0 && prod + dy * ONE_PIXEL >= 0) {
                    prod += dy * ONE_PIXEL;
                    var fx2 = ONE_PIXEL;
                    var fy2 = udiv(prod, dxR);
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * (fx1 + fx2);
                    fx1 = 0;
                    fy1 = fy2;
                    ex1++;
                }
                else {
                    var fx2 = udiv(prod, -dyR);
                    var fy2 = 0;
                    prod += dx * ONE_PIXEL;
                    cover += fy2 - fy1;
                    area += (fy2 - fy1) * (fx1 + fx2);
                    fx1 = fx2;
                    fy1 = ONE_PIXEL;
                    ey1--;
                }
                setCell(ex1, ey1);
                if (ex1 == ex2 && ey1 == ey2)
                    break;
            }
        }
        var fx2 = fract(toX);
        var fy2 = fract(toY);
        cover += fy2 - fy1;
        area += (fy2 - fy1) * (fx1 + fx2);
        px = toX;
        py = toY;
    }

    function fixedQuadTo(controlX:Int, controlY:Int, toX:Int, toY:Int):Void {
        var arcX = this.arcX;
        var arcY = this.arcY;
        arcX[0] = toX;
        arcY[0] = toY;
        arcX[1] = controlX;
        arcY[1] = controlY;
        arcX[2] = px;
        arcY[2] = py;
        if ((trunc(arcY[0]) >= height && trunc(arcY[1]) >= height && trunc(arcY[2]) >= height)
            || (trunc(arcY[0]) < 0 && trunc(arcY[1]) < 0 && trunc(arcY[2]) < 0)) {
            px = arcX[0];
            py = arcY[0];
            return;
        }
        var dx = abs(arcX[2] + arcX[0] - 2 * arcX[1]);
        var dy = abs(arcY[2] + arcY[0] - 2 * arcY[1]);
        if (dx < dy)
            dx = dy;
        var draw = 1;
        while (dx > Std.int(ONE_PIXEL / 4)) {
            dx >>= 2;
            draw <<= 1;
        }
        var a = 0;
        while (true) {
            var split = draw & (-draw);
            while (true) {
                split >>= 1;
                if (split == 0)
                    break;
                splitQuad(a);
                a += 2;
            }
            fixedLineTo(arcX[a], arcY[a]);
            draw--;
            if (draw == 0)
                break;
            a -= 2;
        }
    }

    function fixedCubicTo(c1x:Int, c1y:Int, c2x:Int, c2y:Int, toX:Int, toY:Int):Void {
        var arcX = this.arcX;
        var arcY = this.arcY;
        arcX[0] = toX;
        arcY[0] = toY;
        arcX[1] = c2x;
        arcY[1] = c2y;
        arcX[2] = c1x;
        arcY[2] = c1y;
        arcX[3] = px;
        arcY[3] = py;
        if ((trunc(arcY[0]) >= height && trunc(arcY[1]) >= height && trunc(arcY[2]) >= height && trunc(arcY[3]) >= height)
            || (trunc(arcY[0]) < 0 && trunc(arcY[1]) < 0 && trunc(arcY[2]) < 0 && trunc(arcY[3]) < 0)) {
            px = arcX[0];
            py = arcY[0];
            return;
        }
        var half = Std.int(ONE_PIXEL / 2);
        var a = 0;
        while (true) {
            if (abs(2 * arcX[a] - 3 * arcX[a + 1] + arcX[a + 3]) > half
                || abs(2 * arcY[a] - 3 * arcY[a + 1] + arcY[a + 3]) > half
                || abs(arcX[a] - 3 * arcX[a + 2] + 2 * arcX[a + 3]) > half
                || abs(arcY[a] - 3 * arcY[a + 2] + 2 * arcY[a + 3]) > half) {
                if (arcX.length - a >= 7) {
                    splitCubic(a);
                    a += 3;
                    continue;
                }
                else {
                    fixedLineTo(toX, toY);
                    return;
                }
            }
            fixedLineTo(arcX[a], arcY[a]);
            if (a == 0)
                return;
            a -= 3;
        }
    }

    inline function splitQuad(o:Int):Void {
        splitQuadAxis(arcX, o);
        splitQuadAxis(arcY, o);
    }

    static inline function splitQuadAxis(b:Array<Int>, o:Int):Void {
        b[o + 4] = b[o + 2];
        var a = b[o] + b[o + 1];
        var c = b[o + 1] + b[o + 2];
        b[o + 3] = c >> 1;
        b[o + 2] = (a + c) >> 2;
        b[o + 1] = a >> 1;
    }

    inline function splitCubic(o:Int):Void {
        splitCubicAxis(arcX, o);
        splitCubicAxis(arcY, o);
    }

    static inline function splitCubicAxis(base:Array<Int>, o:Int):Void {
        base[o + 6] = base[o + 3];
        var a = base[o] + base[o + 1];
        var b = base[o + 1] + base[o + 2];
        var c = base[o + 2] + base[o + 3];
        base[o + 5] = c >> 1;
        c += b;
        base[o + 4] = c >> 2;
        base[o + 1] = a >> 1;
        a += b;
        base[o + 2] = a >> 2;
        base[o + 3] = (a + c) >> 3;
    }

/// Output

    static inline function coverage(c:Int):Int {
        c >>= PIXEL_BITS * 2 + 1 - 8;
        if (c < 0)
            c = ~c;
        if (c >= 256)
            c = 255;
        return c;
    }

    /**
     * Finishes the path and writes the coverage into `dst` (`stride` bytes
     * per row, starting at `offset`), top row first. Every pixel of the
     * `width` x `height` area is written.
     */
    public function render(dst:Bytes, offset:Int, stride:Int):Void {
        if (!closed)
            fixedLineTo(startX, startY);
        if (!invalid)
            storeCell(cellX, cellY, area, cover);
        invalid = true;

        var w1 = width + 1;
        for (y in 0...height) {
            var row = offset + (height - 1 - y) * stride;
            var base = y * w1;
            var acc = 0;
            // Cell at x = -1 only contributes its cover
            if (used.get(base) != 0)
                acc += covers[base] * (ONE_PIXEL * 2);
            for (x in 0...width) {
                var i = base + x + 1;
                var value:Int;
                if (used.get(i) != 0) {
                    acc += covers[i] * (ONE_PIXEL * 2);
                    var a = acc - areas[i];
                    value = a != 0 ? coverage(a) : 0;
                }
                else {
                    value = acc != 0 ? coverage(acc) : 0;
                }
                dst.set(row + x, value);
            }
        }
    }

}
