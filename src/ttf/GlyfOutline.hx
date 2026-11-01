// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * TrueType outlines (`glyf` and `loca` tables): simple glyphs with
 * quadratic curves and composite glyphs (with scales, 2x2 transforms and
 * point matching). Hinting instructions are ignored.
 *
 * Points are decoded into reusable buffers, then emitted contour by
 * contour with the same rules as FreeType's outline decomposition
 * (implicit on-curve points between two off-curve points).
 */
class GlyfOutline {

    static inline var MAX_DEPTH = 16;

    var data:Bytes;

    var glyf:Int;

    var glyfLength:Int;

    var loca:Int;

    var locaLong:Bool;

    var numGlyphs:Int;

    // Decoded points, in font units (already transformed for composites)
    var xs:Array<Float> = [];
    var ys:Array<Float> = [];
    var onCurve:Array<Bool> = [];
    var numPoints:Int = 0;

    // Index of the last point of each contour
    var ends:Array<Int> = [];
    var numContours:Int = 0;

    // Scratch for flags of a simple glyph
    var flags:Array<Int> = [];

    public function new(data:Bytes, glyf:Int, glyfLength:Int, loca:Int, locaLong:Bool, numGlyphs:Int) {
        this.data = data;
        this.glyf = glyf;
        this.glyfLength = glyfLength;
        this.loca = loca;
        this.locaLong = locaLong;
        this.numGlyphs = numGlyphs;
    }

    /**
     * Offset of the glyph data in the font, or -1 if the glyph is empty.
     */
    inline function glyphOffset(gid:Int):Int {
        var start:Int;
        var end:Int;
        if (locaLong) {
            start = u32(data, loca + gid * 4);
            end = u32(data, loca + gid * 4 + 4);
        }
        else {
            start = u16(data, loca + gid * 2) * 2;
            end = u16(data, loca + gid * 2 + 2) * 2;
        }
        return (end > start && end <= glyfLength) ? glyf + start : -1;
    }

    /**
     * Emits the outline of `gid` into `sink`. Returns false if the glyph
     * has no outline (empty glyph or invalid id).
     */
    public function decompose(gid:Int, sink:OutlineSink):Bool {

        if (gid < 0 || gid >= numGlyphs)
            return false;

        numPoints = 0;
        numContours = 0;
        load(gid, 1, 0, 0, 1, 0, 0, 0);

        if (numContours == 0)
            return false;

        emit(sink);
        return true;

    }

    /**
     * Number of points of the last decomposed glyph (for tests).
     */
    public inline function lastPointCount():Int {
        return numPoints;
    }

    inline function addPoint(x:Float, y:Float, on:Bool):Void {
        var i = numPoints;
        if (i < xs.length) {
            xs[i] = x;
            ys[i] = y;
            onCurve[i] = on;
        }
        else {
            xs.push(x);
            ys.push(y);
            onCurve.push(on);
        }
        numPoints = i + 1;
    }

    inline function addContourEnd(index:Int):Void {
        if (numContours < ends.length)
            ends[numContours] = index;
        else
            ends.push(index);
        numContours++;
    }

    function load(gid:Int, a:Float, b:Float, c:Float, d:Float, e:Float, f:Float, depth:Int):Void {

        if (depth > MAX_DEPTH || gid < 0 || gid >= numGlyphs)
            return;

        var off = glyphOffset(gid);
        if (off < 0)
            return;

        var bytes = data;
        var nContours = s16(bytes, off);

        if (nContours >= 0) {
            // Simple glyph
            if (nContours == 0)
                return;
            var p = off + 10;
            var firstPoint = numPoints;
            var nPoints = u16(bytes, p + (nContours - 1) * 2) + 1;
            for (i in 0...nContours) {
                addContourEnd(firstPoint + u16(bytes, p + i * 2));
            }
            p += nContours * 2;
            var instructionLength = u16(bytes, p);
            p += 2 + instructionLength;

            // Flags
            var flags = this.flags;
            var i = 0;
            while (i < nPoints) {
                var flag = bytes.get(p++);
                if (i < flags.length) flags[i] = flag else flags.push(flag);
                i++;
                if ((flag & 8) != 0) {
                    var repeat = bytes.get(p++);
                    while (repeat > 0 && i < nPoints) {
                        if (i < flags.length) flags[i] = flag else flags.push(flag);
                        i++;
                        repeat--;
                    }
                }
            }

            // X coordinates (stored temporarily in xs)
            var x = 0;
            for (n in 0...nPoints) {
                var flag = flags[n];
                if ((flag & 2) != 0) {
                    var dx = bytes.get(p++);
                    x += (flag & 16) != 0 ? dx : -dx;
                }
                else if ((flag & 16) == 0) {
                    x += s16(bytes, p);
                    p += 2;
                }
                addPoint(x, 0, (flag & 1) != 0);
            }

            // Y coordinates, then transform
            var y = 0;
            for (n in 0...nPoints) {
                var flag = flags[n];
                if ((flag & 4) != 0) {
                    var dy = bytes.get(p++);
                    y += (flag & 32) != 0 ? dy : -dy;
                }
                else if ((flag & 32) == 0) {
                    y += s16(bytes, p);
                    p += 2;
                }
                var k = firstPoint + n;
                var px = xs[k];
                xs[k] = a * px + c * y + e;
                ys[k] = b * px + d * y + f;
            }
            return;
        }

        // Composite glyph
        var p = off + 10;
        var compositeStart = numPoints;
        while (true) {
            var flags = u16(bytes, p);
            var glyphIndex = u16(bytes, p + 2);
            p += 4;

            var arg1:Int;
            var arg2:Int;
            var argsAreXY = (flags & 0x0002) != 0;
            if ((flags & 0x0001) != 0) {
                if (argsAreXY) {
                    arg1 = s16(bytes, p);
                    arg2 = s16(bytes, p + 2);
                }
                else {
                    arg1 = u16(bytes, p);
                    arg2 = u16(bytes, p + 2);
                }
                p += 4;
            }
            else {
                if (argsAreXY) {
                    arg1 = s8(bytes, p);
                    arg2 = s8(bytes, p + 1);
                }
                else {
                    arg1 = bytes.get(p);
                    arg2 = bytes.get(p + 1);
                }
                p += 2;
            }

            var ma = 1.0;
            var mb = 0.0;
            var mc = 0.0;
            var md = 1.0;
            if ((flags & 0x0008) != 0) {
                ma = md = f2dot14(bytes, p);
                p += 2;
            }
            else if ((flags & 0x0040) != 0) {
                ma = f2dot14(bytes, p);
                md = f2dot14(bytes, p + 2);
                p += 4;
            }
            else if ((flags & 0x0080) != 0) {
                ma = f2dot14(bytes, p);
                mb = f2dot14(bytes, p + 2);
                mc = f2dot14(bytes, p + 4);
                md = f2dot14(bytes, p + 6);
                p += 8;
            }

            // Compose parent (a b c d) with component (ma mb mc md)
            var na = a * ma + c * mb;
            var nb = b * ma + d * mb;
            var nc = a * mc + c * md;
            var nd = b * mc + d * md;

            var childStart = numPoints;
            load(glyphIndex, na, nb, nc, nd, e, f, depth + 1);

            var tx = 0.0;
            var ty = 0.0;
            if (argsAreXY) {
                var dx:Float = arg1;
                var dy:Float = arg2;
                if ((flags & 0x0800) != 0 && (flags & 0x1000) == 0) {
                    // Offset expressed in the scaled component space
                    var sx = dx * ma + dy * mc;
                    var sy = dx * mb + dy * md;
                    dx = sx;
                    dy = sy;
                }
                tx = a * dx + c * dy;
                ty = b * dx + d * dy;
            }
            else {
                // Point matching: align child point arg2 on parent point arg1
                var parentIndex = compositeStart + arg1;
                var childIndex = childStart + arg2;
                if (parentIndex < childStart && childIndex < numPoints) {
                    tx = xs[parentIndex] - xs[childIndex];
                    ty = ys[parentIndex] - ys[childIndex];
                }
            }
            if (tx != 0 || ty != 0) {
                for (k in childStart...numPoints) {
                    xs[k] += tx;
                    ys[k] += ty;
                }
            }

            if ((flags & 0x0020) == 0)
                break;
        }

    }

    /**
     * Emits the outline of `gid` scaled to `ppem` pixels per em the way
     * FreeType (and skrifa, the scaler of swash) loads unhinted TrueType
     * glyphs: every point is scaled to 26.6 fixed point with `FT_MulFix`
     * and a 16.16 scale of `FT_DivFix(ppem * 64, unitsPerEm)`, composite
     * transforms and offsets are applied to the scaled points in fixed
     * point, and implied on-curve points are integer midpoints. The sink
     * receives pixel coordinates (multiples of 1/64), y up.
     */
    public function decomposeScaled(gid:Int, ppem:Float, unitsPerEm:Int, sink:OutlineSink):Bool {

        if (gid < 0 || gid >= numGlyphs || unitsPerEm <= 0)
            return false;

        numPoints = 0;
        numContours = 0;
        loadScaled(gid, divFix(Std.int(ppem * 64), unitsPerEm), 0);

        if (numContours == 0)
            return false;

        emitScaled(sink);
        return true;

    }

    /** `FT_MulFix` / skrifa `Fixed * Fixed`: (a * b) / 0x10000, rounded. */
    static inline function mulFix(a:Float, b:Float):Int {
        var ab = a * b;
        return Std.int(Math.floor((ab + 0x8000 - (ab < 0 ? 1 : 0)) / 65536.0));
    }

    /** `FT_DivFix` / skrifa `Fixed / Fixed`: (a * 0x10000) / b, rounded. */
    static function divFix(a:Int, b:Int):Int {
        var neg = (a < 0) != (b < 0);
        var au:Float = a < 0 ? -a : a;
        var bu:Float = b < 0 ? -b : b;
        var q = Math.floor((au * 65536.0 + Math.floor(bu / 2)) / bu);
        return Std.int(neg ? -q : q);
    }

    /** Like `load()`, but stores 26.6 scaled points (see `decomposeScaled()`). */
    function loadScaled(gid:Int, scale:Int, depth:Int):Void {

        if (depth > MAX_DEPTH || gid < 0 || gid >= numGlyphs)
            return;

        var off = glyphOffset(gid);
        if (off < 0)
            return;

        var bytes = data;
        var nContours = s16(bytes, off);

        if (nContours >= 0) {
            // Simple glyph
            if (nContours == 0)
                return;
            var p = off + 10;
            var firstPoint = numPoints;
            var nPoints = u16(bytes, p + (nContours - 1) * 2) + 1;
            for (i in 0...nContours) {
                addContourEnd(firstPoint + u16(bytes, p + i * 2));
            }
            p += nContours * 2;
            var instructionLength = u16(bytes, p);
            p += 2 + instructionLength;

            var flags = this.flags;
            var i = 0;
            while (i < nPoints) {
                var flag = bytes.get(p++);
                if (i < flags.length) flags[i] = flag else flags.push(flag);
                i++;
                if ((flag & 8) != 0) {
                    var repeat = bytes.get(p++);
                    while (repeat > 0 && i < nPoints) {
                        if (i < flags.length) flags[i] = flag else flags.push(flag);
                        i++;
                        repeat--;
                    }
                }
            }

            var x = 0;
            for (n in 0...nPoints) {
                var flag = flags[n];
                if ((flag & 2) != 0) {
                    var dx = bytes.get(p++);
                    x += (flag & 16) != 0 ? dx : -dx;
                }
                else if ((flag & 16) == 0) {
                    x += s16(bytes, p);
                    p += 2;
                }
                addPoint(mulFix(x, scale), 0, (flag & 1) != 0);
            }

            var y = 0;
            for (n in 0...nPoints) {
                var flag = flags[n];
                if ((flag & 4) != 0) {
                    var dy = bytes.get(p++);
                    y += (flag & 32) != 0 ? dy : -dy;
                }
                else if ((flag & 32) == 0) {
                    y += s16(bytes, p);
                    p += 2;
                }
                ys[firstPoint + n] = mulFix(y, scale);
            }
            return;
        }

        // Composite glyph
        var p = off + 10;
        var compositeStart = numPoints;
        while (true) {
            var flags = u16(bytes, p);
            var glyphIndex = u16(bytes, p + 2);
            p += 4;

            var arg1:Int;
            var arg2:Int;
            var argsAreXY = (flags & 0x0002) != 0;
            if ((flags & 0x0001) != 0) {
                if (argsAreXY) {
                    arg1 = s16(bytes, p);
                    arg2 = s16(bytes, p + 2);
                }
                else {
                    arg1 = u16(bytes, p);
                    arg2 = u16(bytes, p + 2);
                }
                p += 4;
            }
            else {
                if (argsAreXY) {
                    arg1 = s8(bytes, p);
                    arg2 = s8(bytes, p + 1);
                }
                else {
                    arg1 = bytes.get(p);
                    arg2 = bytes.get(p + 1);
                }
                p += 2;
            }

            // F2Dot14 values as 16.16 fixed point (bits * 4)
            var xx = 0x10000;
            var yx = 0;
            var xy = 0;
            var yy = 0x10000;
            var haveTransform = true;
            if ((flags & 0x0008) != 0) {
                xx = yy = s16(bytes, p) * 4;
                p += 2;
            }
            else if ((flags & 0x0040) != 0) {
                xx = s16(bytes, p) * 4;
                yy = s16(bytes, p + 2) * 4;
                p += 4;
            }
            else if ((flags & 0x0080) != 0) {
                xx = s16(bytes, p) * 4;
                yx = s16(bytes, p + 2) * 4;
                xy = s16(bytes, p + 4) * 4;
                yy = s16(bytes, p + 6) * 4;
                p += 8;
            }
            else {
                haveTransform = false;
            }

            var childStart = numPoints;
            loadScaled(glyphIndex, scale, depth + 1);

            if (haveTransform) {
                for (k in childStart...numPoints) {
                    var px = xs[k];
                    var py = ys[k];
                    xs[k] = mulFix(px, xx) + mulFix(py, xy);
                    ys[k] = mulFix(px, yx) + mulFix(py, yy);
                }
            }

            var tx = 0.0;
            var ty = 0.0;
            if (argsAreXY) {
                var dx = arg1;
                var dy = arg2;
                if (haveTransform && (flags & 0x1800) == 0x0800) {
                    // FreeType's "guess" for scaled component offsets
                    dx = mulFix(dx, hypot(xx, xy));
                    dy = mulFix(dy, hypot(yy, yx));
                }
                tx = mulFix(dx, scale);
                ty = mulFix(dy, scale);
            }
            else {
                // Point matching: align child point arg2 on parent point arg1
                var parentIndex = compositeStart + arg1;
                var childIndex = childStart + arg2;
                if (parentIndex < childStart && childIndex < numPoints) {
                    tx = xs[parentIndex] - xs[childIndex];
                    ty = ys[parentIndex] - ys[childIndex];
                }
            }
            if (tx != 0 || ty != 0) {
                for (k in childStart...numPoints) {
                    xs[k] += tx;
                    ys[k] += ty;
                }
            }

            if ((flags & 0x0020) == 0)
                break;
        }

    }

    static inline function hypot(a:Int, b:Int):Int {
        if (a < 0) a = -a;
        if (b < 0) b = -b;
        return a > b ? a + ((3 * b) >> 3) : b + ((3 * a) >> 3);
    }

    /** `emit()` for 26.6 points: integer midpoints, pixel output. */
    function emitScaled(sink:OutlineSink):Void {

        var xs = this.xs;
        var ys = this.ys;
        var on = this.onCurve;
        var first = 0;
        final k = 1 / 64;

        for (ci in 0...numContours) {
            var last = ends[ci];
            if (last < first || last >= numPoints) {
                first = last + 1;
                continue;
            }

            var startX:Int;
            var startY:Int;
            var index = first;
            var limit = last;

            if (on[first]) {
                startX = Std.int(xs[first]);
                startY = Std.int(ys[first]);
                index = first + 1;
            }
            else if (on[last]) {
                startX = Std.int(xs[last]);
                startY = Std.int(ys[last]);
                limit = last - 1;
            }
            else {
                startX = Std.int((xs[first] + xs[last]) / 2);
                startY = Std.int((ys[first] + ys[last]) / 2);
            }

            sink.moveTo(startX * k, startY * k);

            var hasControl = false;
            var cx = 0;
            var cy = 0;
            while (index <= limit) {
                var px = Std.int(xs[index]);
                var py = Std.int(ys[index]);
                if (on[index]) {
                    if (hasControl) {
                        sink.quadTo(cx * k, cy * k, px * k, py * k);
                        hasControl = false;
                    }
                    else {
                        sink.lineTo(px * k, py * k);
                    }
                }
                else {
                    if (hasControl) {
                        sink.quadTo(cx * k, cy * k, Std.int((cx + px) / 2) * k, Std.int((cy + py) / 2) * k);
                    }
                    cx = px;
                    cy = py;
                    hasControl = true;
                }
                index++;
            }

            if (hasControl)
                sink.quadTo(cx * k, cy * k, startX * k, startY * k);
            else
                sink.lineTo(startX * k, startY * k);

            sink.close();
            first = last + 1;
        }

    }

    function emit(sink:OutlineSink):Void {

        var xs = this.xs;
        var ys = this.ys;
        var on = this.onCurve;
        var first = 0;

        for (ci in 0...numContours) {
            var last = ends[ci];
            if (last < first || last >= numPoints) {
                first = last + 1;
                continue;
            }

            var startX:Float;
            var startY:Float;
            var index = first;
            var limit = last;

            if (on[first]) {
                startX = xs[first];
                startY = ys[first];
                index = first + 1;
            }
            else if (on[last]) {
                startX = xs[last];
                startY = ys[last];
                limit = last - 1;
            }
            else {
                startX = (xs[first] + xs[last]) * 0.5;
                startY = (ys[first] + ys[last]) * 0.5;
            }

            sink.moveTo(startX, startY);

            var hasControl = false;
            var cx = 0.0;
            var cy = 0.0;
            while (index <= limit) {
                var px = xs[index];
                var py = ys[index];
                if (on[index]) {
                    if (hasControl) {
                        sink.quadTo(cx, cy, px, py);
                        hasControl = false;
                    }
                    else {
                        sink.lineTo(px, py);
                    }
                }
                else {
                    if (hasControl) {
                        sink.quadTo(cx, cy, (cx + px) * 0.5, (cy + py) * 0.5);
                    }
                    cx = px;
                    cy = py;
                    hasControl = true;
                }
                index++;
            }

            if (hasControl)
                sink.quadTo(cx, cy, startX, startY);
            else
                sink.lineTo(startX, startY);

            sink.close();
            first = last + 1;
        }

    }

}
