// Ported from swash 0.2.10: src/scale/mod.rs (Render::render_into with
// Source::ColorOutline(0) then Source::ColorBitmap(StrikeWith::BestFit),
// Scaler::scale_bitmap_impl) and src/scale/bitmap/mod.rs (blit)
// Original code Copyright 2020 Chad Brokaw, licensed under MIT / Apache-2.0.
// Modified: translated from Rust to Haxe, part of the ttf library for Ceramic,
// on top of the ttf outline rasterizer.
package ttf.color;

import haxe.io.Bytes;
import ttf.GlyphRasterizer;

/**
 * Color glyphs of a font, rendered the way swash renders emoji for GPUI's
 * font file based text system (`Render::new(&[ColorOutline(0),
 * ColorBitmap(BestFit), Outline])`):
 *
 * 1. `COLR` / `CPAL` layers (palette 0), each layer outline rasterized and
 *    blended over the previous ones (swash's `blit`);
 * 2. else the bitmap of the strike that fits (`sbix`, else `CBDT`): the
 *    first strike at least as large as the size, scaled to the size with a
 *    Mitchell filter, placed with the strike's offsets scaled the same way.
 *
 * Images are RGBA with straight alpha (`ColorBitmap`). Glyphs without color
 * data (`hasColorGlyph()` false) are left to the outline rasterizer.
 *
 * Get it with `Font.color()`. Scratch buffers are reused: use it from one
 * thread.
 */
class ColorGlyphs {

    public final font:Font;

    public final colr:Null<Colr>;

    public final sbix:Null<Sbix>;

    public final cbdt:Null<Cbdt>;

    /** Color of the layers that use the text color (swash's default foreground), `0xAARRGGBB` */
    public var foreground:Int = 0xFF808080;

    final glyph = new BitmapGlyph();

    var png:Null<Png> = null;

    var scaler:Null<BitmapScaler> = null;

    var rasterizer:Null<GlyphRasterizer> = null;

    final decoded = new ColorBitmap();

    final layerMask = new GlyphBitmap();

    final box = new GlyphBox();

    /** True if the font has `COLR` + `CPAL`, `sbix` or `CBLC` + `CBDT` tables. */
    public static function hasColorTables(font:Font):Bool {
        return (font.hasTable('COLR') && font.hasTable('CPAL')) || font.hasTable('sbix')
            || (font.hasTable('CBLC') && font.hasTable('CBDT'));
    }

    public function new(font:Font) {
        this.font = font;
        colr = font.hasTable('COLR') && font.hasTable('CPAL') ? new Colr(font) : null;
        sbix = font.hasTable('sbix') ? new Sbix(font) : null;
        cbdt = sbix == null && font.hasTable('CBLC') && font.hasTable('CBDT') ? new Cbdt(font) : null;
    }

    /** True if the glyph has color layers or a color bitmap. */
    public function hasColorGlyph(gid:Int):Bool {
        if (colr != null && colr.layerCount(gid) > 0)
            return true;
        if (sbix != null && sbix.findStrike(0, gid) >= 0)
            return true;
        if (cbdt != null && cbdt.findStrike(0, gid) >= 0)
            return true;
        return false;
    }

    /**
     * Placement of a color glyph rendered at `size` pixels per em with the
     * given subpixel offset (pixels, y up; only `COLR` glyphs use it, like
     * swash). `out.data` is set to null. Returns false (and an empty `out`)
     * if the glyph has no color data.
     */
    public function bounds(gid:Int, size:Float, offsetX:Float, offsetY:Float, out:ColorBitmap):Bool {
        return render(gid, size, offsetX, offsetY, out, false);
    }

    /**
     * Renders a color glyph at `size` pixels per em into `out` (RGBA,
     * straight alpha). Returns false (and an empty `out`) if the glyph has
     * no color data or its image cannot be decoded.
     */
    public function rasterize(gid:Int, size:Float, offsetX:Float, offsetY:Float, out:ColorBitmap):Bool {
        return render(gid, size, offsetX, offsetY, out, true);
    }

    function render(gid:Int, size:Float, offsetX:Float, offsetY:Float, out:ColorBitmap, pixels:Bool):Bool {
        out.clear();
        if (size <= 0)
            return false;
        if (colr != null && colr.layerCount(gid) > 0)
            return renderLayers(gid, size, offsetX, offsetY, out, pixels);
        if (sbix != null) {
            var strike = sbix.findStrike(Std.int(size), gid);
            if (strike >= 0 && sbix.glyph(strike, gid, glyph))
                return renderBitmap(size, out, pixels);
        }
        else if (cbdt != null) {
            var strike = cbdt.findStrike(Std.int(size), gid);
            if (strike >= 0 && cbdt.glyph(strike, gid, glyph))
                return renderBitmap(size, out, pixels);
        }
        return false;
    }

/// Bitmaps

    function renderBitmap(size:Float, out:ColorBitmap, pixels:Bool):Bool {
        var g = glyph;
        if (g.ppem <= 0)
            return false;
        var scale = size / g.ppem;
        var w = g.width;
        var h = g.height;
        var scaled = scale != 1.0;
        if (scaled) {
            // `as u32` / `as i32` truncate toward zero
            w = Std.int(w * scale);
            h = Std.int(h * scale);
            out.left = Std.int(g.left * scale);
            out.top = Std.int(g.top * scale);
        }
        else {
            out.left = g.left;
            out.top = g.top;
        }
        if (w <= 0 || h <= 0) {
            out.clear();
            return false;
        }
        out.width = w;
        out.height = h;
        if (!pixels)
            return true;
        if (png == null)
            png = new Png();
        var image = scaled ? decoded : out;
        var left = out.left;
        var top = out.top;
        if (!png.decode(g.bytes, g.pos, g.length, image) || image.width != g.width || image.height != g.height) {
            out.clear();
            return false;
        }
        if (g.flip)
            image.flipHorizontally();
        if (scaled) {
            if (scaler == null)
                scaler = new BitmapScaler();
            out.allocate(w, h);
            scaler.resize(decoded.data, decoded.width, decoded.height, out.data, w, h);
        }
        out.left = left;
        out.top = top;
        return true;
    }

/// Layers

    function renderLayers(gid:Int, size:Float, offsetX:Float, offsetY:Float, out:ColorBitmap, pixels:Bool):Bool {
        var c = colr;
        var count = c.layerCount(gid);
        if (rasterizer == null)
            rasterizer = new GlyphRasterizer();
        // Bounds of every layer outline
        var minX = Math.POSITIVE_INFINITY;
        var minY = Math.POSITIVE_INFINITY;
        var maxX = Math.NEGATIVE_INFINITY;
        var maxY = Math.NEGATIVE_INFINITY;
        for (i in 0...count) {
            if (!rasterizer.scaledBounds(font, c.layerGlyph(gid, i), size, box))
                continue;
            if (box.xMin < minX) minX = box.xMin;
            if (box.yMin < minY) minY = box.yMin;
            if (box.xMax > maxX) maxX = box.xMax;
            if (box.yMax > maxY) maxY = box.yMax;
        }
        if (minX > maxX || minY > maxY)
            return false;
        var baseX = Math.floor(minX + offsetX);
        var baseY = Math.ceil(minY + offsetY);
        var baseW = Math.ceil(maxX - minX);
        var baseH = Math.ceil(maxY - minY);
        if (baseW <= 0 || baseH <= 0)
            return false;
        out.left = baseX;
        out.top = baseH + baseY;
        out.width = baseW;
        out.height = baseH;
        if (!pixels)
            return true;
        var left = out.left;
        var top = out.top;
        out.allocate(baseW, baseH);
        out.left = left;
        out.top = top;
        for (i in 0...count) {
            var mask = rasterizer.rasterize(font, c.layerGlyph(gid, i), size, offsetX, offsetY, layerMask);
            if (mask.width <= 0 || mask.height <= 0)
                continue;
            var index = c.layerPaletteIndex(gid, i);
            var color = index == 0xFFFF ? -1 : c.paletteColor(0, index);
            if (color == -1)
                color = foreground;
            blit(mask.data, mask.width, mask.height, mask.left - baseX, (baseH + baseY) - mask.top, color, out.data, baseW, baseH);
        }
        return true;
    }

    /**
     * Blends a coverage mask filled with a color (`0xAARRGGBB`) over an
     * RGBA image (swash `bitmap::blit`).
     */
    static function blit(mask:Bytes, maskWidth:Int, maskHeight:Int, x:Int, y:Int, color:Int, target:Bytes, targetWidth:Int, targetHeight:Int):Void {
        var sourceX = x < 0 ? -x : 0;
        var sourceY = y < 0 ? -y : 0;
        if (sourceX >= maskWidth || sourceY >= maskHeight)
            return;
        var destX = x < 0 ? 0 : x;
        var destY = y < 0 ? 0 : y;
        if (destX >= targetWidth || destY >= targetHeight)
            return;
        var sourceEndX = maskWidth < targetWidth - destX + sourceX ? maskWidth : targetWidth - destX + sourceX;
        var sourceEndY = maskHeight < targetHeight - destY + sourceY ? maskHeight : targetHeight - destY + sourceY;
        var cr = (color >> 16) & 0xFF;
        var cg = (color >> 8) & 0xFF;
        var cb = color & 0xFF;
        var ca = (color >>> 24) & 0xFF;
        var dy = destY;
        for (sy in sourceY...sourceEndY) {
            var src = sy * maskWidth;
            var dx = (dy * targetWidth + destX) * 4;
            dy++;
            for (sx in sourceX...sourceEndX) {
                var a = (mask.get(src + sx) * ca) >> 8;
                if (a >= 255) {
                    target.set(dx, cr);
                    target.set(dx + 1, cg);
                    target.set(dx + 2, cb);
                    target.set(dx + 3, 255);
                }
                else if (a != 0) {
                    var ia = 255 - a;
                    target.set(dx, (ia * target.get(dx) + a * cr) >> 8);
                    target.set(dx + 1, (ia * target.get(dx + 1) + a * cg) >> 8);
                    target.set(dx + 2, (ia * target.get(dx + 2) + a * cb) >> 8);
                    target.set(dx + 3, (ia * target.get(dx + 3) + a * 255) >> 8);
                }
                dx += 4;
            }
        }
    }

}
