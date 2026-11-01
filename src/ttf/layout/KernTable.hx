// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Legacy kerning table (`kern`), format 0 subtables with horizontal
 * kerning values. Both the Microsoft (version 0) and Apple (version 1)
 * headers are read. Used only when `GPOS` has no `kern` feature.
 */
class KernTable {

    var data:Bytes;

    /** Absolute offsets of the format 0 pair arrays. */
    var subtables:Array<Int> = [];

    var pairCounts:Array<Int> = [];

    var overrides:Array<Bool> = [];

    public var isEmpty(get, never):Bool;
    inline function get_isEmpty():Bool return subtables.length == 0;

    public function new(data:Bytes, offset:Int, length:Int) {
        this.data = data;
        if (offset < 0)
            return;
        var version = u16(data, offset);
        if (version == 0) {
            var n = u16(data, offset + 2);
            var p = offset + 4;
            for (i in 0...n) {
                var len = u16(data, p + 2);
                var coverage = u16(data, p + 4);
                var format = coverage >> 8;
                var horizontal = (coverage & 1) != 0;
                var minimum = (coverage & 2) != 0;
                var crossStream = (coverage & 4) != 0;
                if (format == 0 && horizontal && !minimum && !crossStream) {
                    subtables.push(p + 14);
                    pairCounts.push(u16(data, p + 6));
                    overrides.push((coverage & 8) != 0);
                }
                p += len;
            }
        }
        else if (version == 1) {
            var n = u32(data, offset + 4);
            var p = offset + 8;
            for (i in 0...n) {
                var len = u32(data, p);
                var coverage = u16(data, p + 4);
                var format = coverage & 0xFF;
                var vertical = (coverage & 0x8000) != 0;
                var crossStream = (coverage & 0x4000) != 0;
                var variation = (coverage & 0x2000) != 0;
                if (format == 0 && !vertical && !crossStream && !variation) {
                    subtables.push(p + 16);
                    pairCounts.push(u16(data, p + 8));
                    overrides.push(false);
                }
                p += len;
            }
        }
    }

    /**
     * Kerning value between two glyphs, in font units.
     */
    public function kerning(left:Int, right:Int):Int {
        var b = data;
        var key = (left << 16) | right;
        var total = 0;
        for (s in 0...subtables.length) {
            var pairs = subtables[s];
            var lo = 0;
            var hi = pairCounts[s] - 1;
            while (lo <= hi) {
                var mid = (lo + hi) >> 1;
                var p = pairs + mid * 6;
                var k = (u16(b, p) << 16) | u16(b, p + 2);
                // Compare as unsigned 32-bit values
                if ((k ^ 0x80000000) < (key ^ 0x80000000)) lo = mid + 1;
                else if (k != key && (k ^ 0x80000000) > (key ^ 0x80000000)) hi = mid - 1;
                else {
                    var v = s16(b, p + 4);
                    if (overrides[s]) total = v else total += v;
                    break;
                }
            }
        }
        return total;
    }

    /**
     * Applies pair kerning between consecutive non mark glyphs.
     */
    public function apply(buf:GlyphBuffer):Void {
        var prev = -1;
        for (i in 0...buf.length) {
            var glyphClass = buf.classes[i];
            if (glyphClass == Gdef.MARK || glyphClass == Gdef.HIDDEN)
                continue;
            if (prev >= 0) {
                var k = kerning(buf.glyphs[prev], buf.glyphs[i]);
                if (k != 0)
                    buf.xAdvance[prev] += k;
            }
            prev = i;
        }
    }

}
