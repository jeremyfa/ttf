// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;

/**
 * An 8-bit coverage bitmap of a glyph, or only its placement when
 * returned by `GlyphRasterizer.rasterBounds()`.
 *
 * `left` is the x of the first column and `top` the y of the top edge of
 * the first row, relative to the glyph origin, with y pointing up (like
 * FreeType's `bitmap_left` / `bitmap_top`). In GPUI terms, the raster
 * bounds are `origin = (left, -top)` and `size = (width, height)`.
 */
class GlyphBitmap {

    public var width:Int = 0;

    public var height:Int = 0;

    public var left:Int = 0;

    public var top:Int = 0;

    /** Coverage values (0 to 255), `width` bytes per row, top row first. Null for bounds only. */
    public var data:Bytes = null;

    public function new() {}

    public inline function isEmpty():Bool {
        return width <= 0 || height <= 0;
    }

}

/**
 * Renders glyph outlines into 8-bit coverage bitmaps without hinting, the
 * way swash renders them for GPUI's `CosmicTextSystem` with hinting off
 * (and like FreeType's unhinted grayscale rendering):
 *
 * - TrueType outlines are scaled to 26.6 fixed point like FreeType and
 *   skrifa (`GlyfOutline.decomposeScaled()`); CFF outlines are scaled in
 *   floating point and rounded to 1/64 of a pixel;
 * - the raster bounds are the control box of the scaled outline, shifted
 *   by the subpixel offset, with floored / ceiled edges (zeno's `Mask`
 *   placement);
 * - coverage comes from `GrayRaster`, a port of zeno's scan converter
 *   (FreeType's smooth rasterizer algorithm), fed with the same fixed
 *   point coordinates.
 *
 * Glyphs can be shifted by a subpixel offset before rendering: GPUI
 * quantizes the horizontal pen position into `SUBPIXEL_VARIANTS_X` (4)
 * variants and renders each variant separately.
 *
 * Scratch buffers are reused: use one rasterizer per thread.
 */
class GlyphRasterizer {

    /** Number of horizontal subpixel variants used by GPUI. */
    public static inline var SUBPIXEL_VARIANTS_X = 4;

    var raster:GrayRaster = new GrayRaster();

    var sink:RasterSink;

    var bounds:BoundsSink = new BoundsSink();

    var scaledCff:ScaledSink;

    var box:GlyphBox = new GlyphBox();

    public function new() {
        sink = new RasterSink(raster);
        scaledCff = new ScaledSink();
    }

    /**
     * Emits the scaled outline of a glyph (pixels, y up) into `target`.
     */
    function scaledOutline(font:Font, gid:Int, fontSize:Float, target:OutlineSink):Bool {
        if (!font.isCff)
            return font.outlineScaled(gid, fontSize, target);
        scaledCff.target = target;
        scaledCff.scale = fontSize / font.unitsPerEm;
        return font.outline(gid, scaledCff);
    }

    /**
     * Control box of the outline of a glyph scaled to `fontSize` pixels per
     * em (pixels, y up), as scaled for rendering. Returns false if the glyph
     * has no outline.
     */
    public function scaledBounds(font:Font, gid:Int, fontSize:Float, out:GlyphBox):Bool {
        bounds.reset();
        if (!scaledOutline(font, gid, fontSize, bounds) || bounds.empty)
            return false;
        out.set(bounds.xMin, bounds.yMin, bounds.xMax, bounds.yMax);
        return true;
    }

    /**
     * Computes the pixel bounds of a glyph rendered at `fontSize` pixels
     * per em with the given subpixel offset (in pixels, x to the right and
     * y up). The result has no `data`.
     */
    public function rasterBounds(font:Font, gid:Int, fontSize:Float, subpixelX:Float, subpixelY:Float, ?out:GlyphBitmap):GlyphBitmap {
        if (out == null)
            out = new GlyphBitmap();
        out.data = null;
        font.glyphBox(gid, box);
        bounds.reset();
        if (box.isEmpty() || !scaledOutline(font, gid, fontSize, bounds) || bounds.empty) {
            out.width = out.height = out.left = out.top = 0;
            return out;
        }
        var left = Math.floor(bounds.xMin + subpixelX);
        var right = Math.ceil(bounds.xMax + subpixelX);
        var bottom = Math.floor(bounds.yMin + subpixelY);
        var top = Math.ceil(bounds.yMax + subpixelY);
        if (right <= left || top <= bottom) {
            out.width = out.height = out.left = out.top = 0;
            return out;
        }
        out.left = left;
        out.top = top;
        out.width = right - left;
        out.height = top - bottom;
        return out;
    }

    /**
     * Renders a glyph. `out.data` is reused when it is large enough.
     * Empty glyphs (spaces) return a bitmap of size 0.
     */
    public function rasterize(font:Font, gid:Int, fontSize:Float, subpixelX:Float, subpixelY:Float, ?out:GlyphBitmap):GlyphBitmap {
        var bitmap = rasterBounds(font, gid, fontSize, subpixelX, subpixelY, out);
        var width = bitmap.width;
        var height = bitmap.height;
        if (width <= 0 || height <= 0)
            return bitmap;

        var size = width * height;
        var data = out != null ? out.data : null;
        if (data == null || data.length < size)
            data = Bytes.alloc(size);
        data.fill(0, size, 0);
        bitmap.data = data;

        renderInto(font, gid, fontSize, subpixelX, subpixelY, bitmap.left, bitmap.top, data, 0, width, width, height);
        return bitmap;
    }

    /**
     * Renders a glyph directly into a destination coverage buffer (for
     * instance an atlas page), at `offset` with the given row `stride`.
     * `left` / `top` are the placement returned by `rasterBounds()` and
     * `width` / `height` the size of the destination area (pixels outside
     * are clipped). Every pixel of the destination area is written.
     */
    public function renderInto(font:Font, gid:Int, fontSize:Float, subpixelX:Float, subpixelY:Float, left:Int, top:Int, dst:Bytes, offset:Int, stride:Int, width:Int, height:Int):Void {
        if (width <= 0 || height <= 0)
            return;
        // Pixel coordinates (y up) relative to the bottom left corner of the area
        raster.reset(width, height);
        sink.shiftX = subpixelX - left;
        sink.shiftY = subpixelY + height - top;
        scaledOutline(font, gid, fontSize, sink);
        raster.render(dst, offset, stride);
    }

    /**
     * Subpixel offset (in pixels) of a GPUI subpixel variant.
     */
    public static inline function subpixelOffset(variant:Int, scaleFactor:Float = 1):Float {
        return variant / SUBPIXEL_VARIANTS_X / scaleFactor;
    }

}

/** Shifts pixel coordinates and feeds them to a `GrayRaster`. */
private class RasterSink implements OutlineSink {

    public var shiftX:Float = 0;

    public var shiftY:Float = 0;

    var raster:GrayRaster;

    public function new(raster:GrayRaster) {
        this.raster = raster;
    }

    public function moveTo(x:Float, y:Float):Void {
        raster.moveTo(x + shiftX, y + shiftY);
    }

    public function lineTo(x:Float, y:Float):Void {
        raster.lineTo(x + shiftX, y + shiftY);
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        raster.quadTo(cx + shiftX, cy + shiftY, x + shiftX, y + shiftY);
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        raster.cubicTo(c1x + shiftX, c1y + shiftY, c2x + shiftX, c2y + shiftY, x + shiftX, y + shiftY);
    }

    public function close():Void {
        raster.close();
    }

}

/** Scales font units to pixels rounded to 1/64 (CFF outlines). */
private class ScaledSink implements OutlineSink {

    public var target:OutlineSink;

    public var scale:Float = 1;

    public function new() {}

    inline function s(v:Float):Float {
        return Math.round(v * scale * 64) / 64;
    }

    public function moveTo(x:Float, y:Float):Void {
        target.moveTo(s(x), s(y));
    }

    public function lineTo(x:Float, y:Float):Void {
        target.lineTo(s(x), s(y));
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        target.quadTo(s(cx), s(cy), s(x), s(y));
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        target.cubicTo(s(c1x), s(c1y), s(c2x), s(c2y), s(x), s(y));
    }

    public function close():Void {
        target.close();
    }

}
