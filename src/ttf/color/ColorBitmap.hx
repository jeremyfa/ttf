// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.color;

import haxe.io.Bytes;

/**
 * A color glyph image: 4 bytes per pixel, straight (not premultiplied)
 * alpha, top row first, in RGBA order (or BGRA after `swapRedBlue()`).
 *
 * `left` and `top` place it like `GlyphBitmap`: x of the first column and
 * y of the top edge relative to the glyph origin, y pointing up. In GPUI
 * terms the raster bounds are `origin = (left, -top)`, `size = (width, height)`.
 */
class ColorBitmap {

    public var width:Int = 0;

    public var height:Int = 0;

    public var left:Int = 0;

    public var top:Int = 0;

    /** Pixels, `width * 4` bytes per row. Null for placement only. */
    public var data:Null<Bytes> = null;

    public function new() {}

    public inline function isEmpty():Bool {
        return width <= 0 || height <= 0;
    }

    /** Sets the size and allocates zeroed pixels. */
    public function allocate(width:Int, height:Int):Void {
        this.width = width;
        this.height = height;
        var size = width * height * 4;
        data = Bytes.alloc(size);
        data.fill(0, size, 0);
    }

    public function clear():ColorBitmap {
        width = 0;
        height = 0;
        left = 0;
        top = 0;
        data = null;
        return this;
    }

    /** Swaps the first and third channel of every pixel (RGBA to BGRA and back). */
    public function swapRedBlue():Void {
        if (data == null)
            return;
        var d = data;
        var i = 0;
        var n = width * height * 4;
        while (i < n) {
            var r = d.get(i);
            d.set(i, d.get(i + 2));
            d.set(i + 2, r);
            i += 4;
        }
    }

    /** Mirrors the image horizontally. */
    public function flipHorizontally():Void {
        if (data == null)
            return;
        var d = data;
        for (y in 0...height) {
            var a = y * width * 4;
            var b = a + (width - 1) * 4;
            while (a < b) {
                for (c in 0...4) {
                    var t = d.get(a + c);
                    d.set(a + c, d.get(b + c));
                    d.set(b + c, t);
                }
                a += 4;
                b -= 4;
            }
        }
    }

    /** Number of pixels with a non-zero alpha. */
    public function opaquePixels():Int {
        if (data == null)
            return 0;
        var count = 0;
        var i = 3;
        var n = width * height * 4;
        while (i < n) {
            if (data.get(i) != 0)
                count++;
            i += 4;
        }
        return count;
    }

}
