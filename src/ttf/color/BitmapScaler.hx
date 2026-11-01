// Ported from swash 0.2.10: src/scale/bitmap/mod.rs (resize, resample, sample_dir, mitchell)
// Original code Copyright 2020 Chad Brokaw, licensed under MIT / Apache-2.0.
// Modified: translated from Rust to Haxe, part of the ttf library for Ceramic
// (RGBA images only, the Mitchell filter swash uses for color bitmaps).
package ttf.color;

import haxe.io.Bytes;

/**
 * Resizes RGBA images (straight alpha) with a separable Mitchell filter,
 * like swash does for the color bitmaps of emoji fonts: horizontally into
 * a scratch image, then vertically. Colors are weighted by alpha.
 */
class BitmapScaler {

    var scratch:Bytes = Bytes.alloc(0);

    final weights = new haxe.ds.Vector<Float>(MAX_WEIGHTS);

    static inline final MAX_WEIGHTS = 64;

    static inline final SUPPORT = 2.0;

    public function new() {}

    /**
     * Resizes `source` (`width` by `height`, RGBA) into `target`
     * (`targetWidth` by `targetHeight`, RGBA).
     */
    public function resize(source:Bytes, width:Int, height:Int, target:Bytes, targetWidth:Int, targetHeight:Int):Void {
        if (targetWidth <= 0 || targetHeight <= 0 || width <= 0 || height <= 0)
            return;
        var scratchSize = targetWidth * height * 4;
        if (scratch.length < scratchSize)
            scratch = Bytes.alloc(scratchSize);
        // Horizontal pass: (x, y) of the source into (x, y) of the scratch
        sampleDir(source, width, height, width * 4, 4, scratch, targetWidth, targetWidth * 4, 4);
        // Vertical pass: rows become columns
        sampleDir(scratch, height, targetWidth, 4, targetWidth * 4, target, targetHeight, 4, targetWidth * 4);
    }

    static inline function mitchell(x:Float):Float {
        if (x < 0)
            x = -x;
        return if (x < 1.0) {
            Math.abs((16.0 + x * x * (21.0 * x - 36.0)) / 18.0);
        }
        else if (x < 2.0) {
            Math.abs((32.0 + x * (-60.0 + x * (36.0 - 7.0 * x))) / 18.0);
        }
        else {
            0.0;
        }
    }

    /**
     * Resamples along one direction (swash `sample_dir`): `width` input
     * samples per line into `newWidth` output samples, for `height` lines.
     * Strides are in bytes: `inX` between samples of a line, `inY` between
     * lines, same for the output.
     */
    function sampleDir(input:Bytes, width:Int, height:Int, inY:Int, inX:Int, output:Bytes, newWidth:Int, outY:Int, outX:Int):Void {
        var ratio = width / newWidth;
        var sratio = ratio > 1.0 ? ratio : 1.0;
        var srcSupport = SUPPORT * sratio;
        var isratio = 1.0 / sratio;
        var s = 1.0 / 255.0;
        for (outx in 0...newWidth) {
            var inx = (outx + 0.5) * ratio;
            var left = Math.floor(inx - srcSupport);
            if (left > width - 1) left = width - 1;
            if (left < 0) left = 0;
            var right = Math.ceil(inx + srcSupport);
            if (right < left + 1) right = left + 1;
            if (right > width) right = width;
            inx -= 0.5;
            while (right - left > MAX_WEIGHTS) {
                right--;
                left++;
            }
            var count = 0;
            var sum = 0.0;
            for (i in left...right) {
                var w = mitchell((i - inx) * isratio);
                weights[count++] = w;
                sum += w;
            }
            var isum = 1.0 / sum;
            for (y in 0...height) {
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
                var p = y * inY + left * inX;
                for (k in 0...count) {
                    var w = weights[k];
                    var pa = input.get(p + 3) * s;
                    r += input.get(p) * s * w * pa;
                    g += input.get(p + 1) * s * w * pa;
                    b += input.get(p + 2) * s * w * pa;
                    a += pa * w;
                    p += inX;
                }
                if (a != 0.0) {
                    var ia = 1.0 / a;
                    r *= ia;
                    g *= ia;
                    b *= ia;
                    a *= isum;
                }
                var o = y * outY + outx * outX;
                output.set(o, toByte(r));
                output.set(o + 1, toByte(g));
                output.set(o + 2, toByte(b));
                output.set(o + 3, toByte(a));
            }
        }
    }

    /** `(v * 255.) as u8`: truncated and saturated */
    static inline function toByte(v:Float):Int {
        var x = v * 255.0;
        return x <= 0 ? 0 : (x >= 255.0 ? 255 : Std.int(x));
    }

}
