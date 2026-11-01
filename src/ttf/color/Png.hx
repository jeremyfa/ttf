// Ported from swash 0.2.10: src/scale/bitmap/png.rs
// Original code Copyright 2020 Chad Brokaw, licensed under MIT / Apache-2.0.
// Modified: translated from Rust to Haxe, part of the ttf library for Ceramic.
// Standard Paeth predictor, Adam7 passes with their own row widths.
package ttf.color;

import haxe.io.Bytes;

/**
 * PNG decoder for the bitmaps of color fonts (`sbix`, `CBDT`): every color
 * type and bit depth of the PNG specification, interlaced or not, decoded
 * to 8-bit RGBA with straight alpha (16-bit samples are truncated to their
 * high byte, like swash).
 *
 * Use one instance per thread: its inflater is reused.
 */
class Png {

    final inflate = new Inflate();

    public function new() {}

    /** Width of a PNG image from its header, or -1 if it is not a PNG. */
    public static function headerWidth(data:Bytes, pos:Int, len:Int):Int {
        if (!isPng(data, pos, len))
            return -1;
        return u32(data, pos + 16);
    }

    /** Height of a PNG image from its header, or -1 if it is not a PNG. */
    public static function headerHeight(data:Bytes, pos:Int, len:Int):Int {
        if (!isPng(data, pos, len))
            return -1;
        return u32(data, pos + 20);
    }

    /** True if the data starts with a PNG signature and an `IHDR` chunk. */
    public static function isPng(data:Bytes, pos:Int, len:Int):Bool {
        if (len < 33 || pos < 0 || pos + len > data.length)
            return false;
        if (data.get(pos) != 0x89 || data.get(pos + 1) != 0x50 || data.get(pos + 2) != 0x4E || data.get(pos + 3) != 0x47
            || data.get(pos + 4) != 0x0D || data.get(pos + 5) != 0x0A || data.get(pos + 6) != 0x1A || data.get(pos + 7) != 0x0A)
            return false;
        return u32(data, pos + 8) == 13 && u32(data, pos + 12) == 0x49484452;
    }

    static inline function u32(b:Bytes, o:Int):Int {
        return (b.get(o) << 24) | (b.get(o + 1) << 16) | (b.get(o + 2) << 8) | b.get(o + 3);
    }

    /**
     * Decodes the PNG image at `data[pos...pos + len]` into `out` (RGBA,
     * straight alpha, `width * 4` bytes per row, top row first). Returns
     * false if the image is invalid or not supported.
     */
    public function decode(data:Bytes, pos:Int, len:Int, out:ColorBitmap):Bool {
        if (!isPng(data, pos, len))
            return false;
        var width = u32(data, pos + 16);
        var height = u32(data, pos + 20);
        var depth = data.get(pos + 24);
        var colorType = data.get(pos + 25);
        if (data.get(pos + 26) != 0 || data.get(pos + 27) != 0)
            return false;
        var interlaced = switch data.get(pos + 28) {
            case 0: false;
            case 1: true;
            case _: return false;
        }
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384)
            return false;
        var channels = switch colorType {
            case 0: // Greyscale
                if (depth != 1 && depth != 2 && depth != 4 && depth != 8 && depth != 16) return false;
                1;
            case 3: // Indexed
                if (depth != 1 && depth != 2 && depth != 4 && depth != 8) return false;
                1;
            case 2: // True color
                if (depth != 8 && depth != 16) return false;
                3;
            case 4: // Greyscale and alpha
                if (depth != 8 && depth != 16) return false;
                2;
            case 6: // True color and alpha
                if (depth != 8 && depth != 16) return false;
                4;
            case _:
                return false;
        }

        // Chunks: gather the compressed data
        var end = pos + len;
        var offset = pos + 33;
        var palette:Null<Bytes> = null;
        var trans:Null<Bytes> = null;
        var idat = new haxe.io.BytesBuffer();
        var idatSingle:Null<Bytes> = null;
        var idatPos = 0;
        var idatLen = 0;
        var idatCount = 0;
        while (true) {
            if (offset + 8 > end)
                return false;
            var chunkLen = u32(data, offset);
            var type = u32(data, offset + 4);
            offset += 8;
            if (chunkLen < 0 || offset + chunkLen > end)
                return false;
            switch type {
                case 0x504C5445: // PLTE
                    palette = data.sub(offset, chunkLen);
                case 0x74524E53: // tRNS
                    trans = data.sub(offset, chunkLen);
                case 0x49444154: // IDAT
                    if (idatCount == 0) {
                        idatPos = offset;
                        idatLen = chunkLen;
                    }
                    else {
                        if (idatCount == 1)
                            idat.addBytes(data, idatPos, idatLen);
                        idat.addBytes(data, offset, chunkLen);
                    }
                    idatCount++;
                case 0x49454E44: // IEND
                    break;
                case _:
            }
            offset += chunkLen + 4;
        }
        if (idatCount == 0)
            return false;
        if (colorType == 3 && palette == null)
            return false;
        var bpp = depth * channels;
        var pitch = (width * bpp + 7) >> 3;
        var expected = interlaced ? (pitch + 1) * height + 7 * height : (pitch + 1) * height;
        var raw:Null<Bytes>;
        if (idatCount == 1) {
            raw = inflate.run(data, idatPos, idatLen, true, expected);
        }
        else {
            var merged = idat.getBytes();
            raw = inflate.run(merged, 0, merged.length, true, expected);
        }
        if (raw == null)
            return false;

        out.allocate(width, height);
        var target = out.data;
        var bwidth = (bpp + 7) >> 3;
        var line = Bytes.alloc(pitch);
        var prev = Bytes.alloc(pitch);
        var state = new PngRows(colorType, depth, palette, trans, target, width);

        if (!interlaced) {
            prev.fill(0, pitch, 0);
            var src = 0;
            for (y in 0...height) {
                if (src + pitch + 1 > raw.length)
                    return false;
                if (!defilter(raw.get(src), raw, src + 1, line, prev, pitch, bwidth))
                    return false;
                src += pitch + 1;
                state.emit(line, 0, y, 1, width);
                var t = prev;
                prev = line;
                line = t;
            }
        }
        else {
            var src = 0;
            for (pass in 0...7) {
                var colStart = COL_START[pass];
                var colInc = COL_INC[pass];
                var rowStart = ROW_START[pass];
                var rowInc = ROW_INC[pass];
                var cols = width > colStart ? Std.int((width - colStart + colInc - 1) / colInc) : 0;
                var rows = height > rowStart ? Std.int((height - rowStart + rowInc - 1) / rowInc) : 0;
                if (cols == 0 || rows == 0)
                    continue;
                var passPitch = (cols * bpp + 7) >> 3;
                prev.fill(0, pitch, 0);
                var y = rowStart;
                while (y < height) {
                    if (src + passPitch + 1 > raw.length)
                        return false;
                    if (!defilter(raw.get(src), raw, src + 1, line, prev, passPitch, bwidth))
                        return false;
                    src += passPitch + 1;
                    state.emit(line, colStart, y, colInc, cols);
                    var t = prev;
                    prev = line;
                    line = t;
                    y += rowInc;
                }
            }
        }
        return true;
    }

    static final ROW_START = [0, 0, 4, 0, 2, 0, 1];
    static final ROW_INC = [8, 8, 8, 4, 4, 2, 2];
    static final COL_START = [0, 4, 0, 2, 0, 1, 0];
    static final COL_INC = [8, 8, 4, 4, 2, 2, 1];

    static function defilter(type:Int, src:Bytes, s:Int, dest:Bytes, last:Bytes, len:Int, bwidth:Int):Bool {
        switch type {
            case 0:
                dest.blit(0, src, s, len);
            case 1:
                for (i in 0...len) {
                    var left = i >= bwidth ? dest.get(i - bwidth) : 0;
                    dest.set(i, (src.get(s + i) + left) & 0xFF);
                }
            case 2:
                for (i in 0...len)
                    dest.set(i, (src.get(s + i) + last.get(i)) & 0xFF);
            case 3:
                for (i in 0...len) {
                    var left = i >= bwidth ? dest.get(i - bwidth) : 0;
                    dest.set(i, (src.get(s + i) + ((left + last.get(i)) >> 1)) & 0xFF);
                }
            case 4:
                for (i in 0...len) {
                    var a = i >= bwidth ? dest.get(i - bwidth) : 0;
                    var b = last.get(i);
                    var c = i >= bwidth ? last.get(i - bwidth) : 0;
                    var p = a + b - c;
                    var pa = p > a ? p - a : a - p;
                    var pb = p > b ? p - b : b - p;
                    var pc = p > c ? p - c : c - p;
                    var pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
                    dest.set(i, (src.get(s + i) + pred) & 0xFF);
                }
            case _:
                return false;
        }
        return true;
    }

}

/** Converts the defiltered rows of a PNG image to RGBA (swash `EmitRgba8`). */
private class PngRows {

    final colorType:Int;
    final depth:Int;
    final palette:Null<Bytes>;
    final trans:Null<Bytes>;
    final target:Bytes;
    final width:Int;

    public function new(colorType:Int, depth:Int, palette:Null<Bytes>, trans:Null<Bytes>, target:Bytes, width:Int) {
        this.colorType = colorType;
        this.depth = depth;
        this.palette = palette;
        this.trans = trans;
        this.target = target;
        this.width = width;
    }

    /** Sample `i` of a row of samples of `depth` bits (16-bit samples truncated to 8 bits) */
    inline function sample(row:Bytes, i:Int, scaleLow:Bool):Int {
        return switch depth {
            case 8: row.get(i);
            case 16: row.get(i * 2);
            case 4: ((row.get(i >> 1) >> (4 - (i & 1) * 4)) & 15) * (scaleLow ? 17 : 1);
            case 2: ((row.get(i >> 2) >> (6 - (i & 3) * 2)) & 3) * (scaleLow ? 85 : 1);
            case _: ((row.get(i >> 3) >> (7 - (i & 7))) & 1) * (scaleLow ? 255 : 1);
        }
    }

    public function emit(row:Bytes, x:Int, y:Int, inc:Int, count:Int):Void {
        var out = (y * width + x) * 4;
        var step = inc * 4;
        switch colorType {
            case 3:
                var pal = palette;
                var palLen = pal.length;
                var transLen = trans != null ? trans.length : 0;
                for (i in 0...count) {
                    var t = sample(row, i, false);
                    var p = t * 3;
                    if (p + 2 >= palLen) {
                        target.set(out, 0);
                        target.set(out + 1, 0);
                        target.set(out + 2, 0);
                    }
                    else {
                        target.set(out, pal.get(p));
                        target.set(out + 1, pal.get(p + 1));
                        target.set(out + 2, pal.get(p + 2));
                    }
                    target.set(out + 3, t < transLen ? trans.get(t) : 255);
                    out += step;
                }
            case 2:
                for (i in 0...count) {
                    target.set(out, sample(row, i * 3, true));
                    target.set(out + 1, sample(row, i * 3 + 1, true));
                    target.set(out + 2, sample(row, i * 3 + 2, true));
                    target.set(out + 3, 255);
                    out += step;
                }
            case 6:
                for (i in 0...count) {
                    target.set(out, sample(row, i * 4, true));
                    target.set(out + 1, sample(row, i * 4 + 1, true));
                    target.set(out + 2, sample(row, i * 4 + 2, true));
                    target.set(out + 3, sample(row, i * 4 + 3, true));
                    out += step;
                }
            case 0:
                for (i in 0...count) {
                    var c = sample(row, i, true);
                    target.set(out, c);
                    target.set(out + 1, c);
                    target.set(out + 2, c);
                    target.set(out + 3, 255);
                    out += step;
                }
            case _:
                for (i in 0...count) {
                    var c = sample(row, i * 2, true);
                    target.set(out, c);
                    target.set(out + 1, c);
                    target.set(out + 2, c);
                    target.set(out + 3, sample(row, i * 2 + 1, true));
                    out += step;
                }
        }
    }

}
