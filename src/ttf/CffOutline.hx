// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Position of an INDEX structure in a CFF or CFF2 table.
 */
class CffIndex {

    public var count:Int = 0;

    var data:Bytes;

    var offSize:Int = 1;

    var offsets:Int = 0;

    /** Position of the byte that precedes the first object (offsets are 1-based). */
    var base:Int = 0;

    /** Position right after the INDEX. */
    public var end(default, null):Int = 0;

    public function new(data:Bytes, pos:Int, cff2:Bool) {
        this.data = data;
        if (pos < 0 || pos >= data.length) {
            end = pos;
            return;
        }
        if (cff2) {
            count = u32(data, pos);
            pos += 4;
        }
        else {
            count = u16(data, pos);
            pos += 2;
        }
        if (count == 0) {
            end = pos;
            return;
        }
        offSize = data.get(pos);
        offsets = pos + 1;
        base = offsets + (count + 1) * offSize - 1;
        end = base + offset(count);
    }

    inline function offset(i:Int):Int {
        var p = offsets + i * offSize;
        return switch offSize {
            case 1: data.get(p);
            case 2: u16(data, p);
            case 3: u24(data, p);
            default: u32(data, p);
        }
    }

    /** Absolute start position of object `i`. */
    public inline function start(i:Int):Int {
        return base + offset(i);
    }

    /** Absolute end position of object `i`. */
    public inline function stop(i:Int):Int {
        return base + offset(i + 1);
    }

}

/**
 * CFF and CFF2 outlines (`CFF ` and `CFF2` tables): a Type 2 charstring
 * interpreter emitting cubic curves.
 *
 * Supported: name-keyed and CID-keyed fonts (FDArray / FDSelect formats
 * 0, 3 and 4), local and global subroutines, hint operators (skipped),
 * flex operators and the common arithmetic operators. For CFF2, `blend`
 * keeps the default instance values (no variations) and `vsindex` is read
 * to know how many operands to drop. The deprecated `seac` form of
 * `endchar` is not supported.
 */
class CffOutline {

    static inline var MAX_STACK = 513;

    static inline var MAX_SUBR_DEPTH = 10;

    var data:Bytes;

    var cff2:Bool;

    var charStrings:CffIndex;

    var globalSubrs:CffIndex;

    var globalBias:Int;

    /** Local subroutines for name-keyed fonts. */
    var localSubrs:CffIndex = null;

    var localBias:Int = 0;

    /** Per font dict local subroutines for CID-keyed and CFF2 fonts. */
    var fdLocalSubrs:Array<CffIndex> = null;

    var fdLocalBias:Array<Int> = null;

    var fdSelect:Int = -1;

    var numGlyphs:Int;

    /** Region count of each item variation data (CFF2 `blend`). */
    var regionCounts:Array<Int> = [];

    var defaultVsIndex:Array<Int> = null;

    // Interpreter state
    var stack:haxe.ds.Vector<Float>;
    var sp:Int = 0;
    var x:Float = 0;
    var y:Float = 0;
    var nStems:Int = 0;
    var haveWidth:Bool = false;
    var open:Bool = false;
    var ended:Bool = false;
    var vsIndex:Int = 0;
    var transient:haxe.ds.Vector<Float>;
    var sink:OutlineSink;
    var subrs:CffIndex;
    var subrBias:Int;

    // DICT parsing scratch
    var operands:Array<Float> = [];

    public function new(data:Bytes, offset:Int, length:Int, cff2:Bool, numGlyphs:Int) {

        this.data = data;
        this.cff2 = cff2;
        this.numGlyphs = numGlyphs;
        stack = new haxe.ds.Vector(MAX_STACK + 1);
        transient = new haxe.ds.Vector(32);

        var hdrSize = data.get(offset + 2);

        var charStringsOffset = -1;
        var privateSize = 0;
        var privateOffset = -1;
        var fdArrayOffset = -1;
        var fdSelectOffset = -1;
        var vstoreOffset = -1;

        var topStart:Int;
        var topEnd:Int;

        if (cff2) {
            var topDictLength = u16(data, offset + 3);
            topStart = offset + hdrSize;
            topEnd = topStart + topDictLength;
            globalSubrs = new CffIndex(data, topEnd, true);
        }
        else {
            var nameIndex = new CffIndex(data, offset + hdrSize, false);
            var topIndex = new CffIndex(data, nameIndex.end, false);
            var stringIndex = new CffIndex(data, topIndex.end, false);
            globalSubrs = new CffIndex(data, stringIndex.end, false);
            topStart = topIndex.start(0);
            topEnd = topIndex.stop(0);
        }
        globalBias = biasFor(globalSubrs.count);

        parseDict(topStart, topEnd, function(op, ops, n) {
            switch op {
                case 17: if (n > 0) charStringsOffset = Std.int(ops[0]);
                case 18: if (n > 1) { privateSize = Std.int(ops[0]); privateOffset = Std.int(ops[1]); }
                case 0x0C24: if (n > 0) fdArrayOffset = Std.int(ops[0]);
                case 0x0C25: if (n > 0) fdSelectOffset = Std.int(ops[0]);
                case 24: if (n > 0) vstoreOffset = Std.int(ops[0]);
                default:
            }
        });

        charStrings = new CffIndex(data, offset + charStringsOffset, cff2);

        if (vstoreOffset > 0)
            parseVariationStore(offset + vstoreOffset);

        if (fdArrayOffset > 0) {
            var fdArray = new CffIndex(data, offset + fdArrayOffset, cff2);
            fdLocalSubrs = [];
            fdLocalBias = [];
            defaultVsIndex = [];
            for (i in 0...fdArray.count) {
                var pSize = 0;
                var pOffset = -1;
                parseDict(fdArray.start(i), fdArray.stop(i), function(op, ops, n) {
                    if (op == 18 && n > 1) {
                        pSize = Std.int(ops[0]);
                        pOffset = Std.int(ops[1]);
                    }
                });
                var subrsIndex:CffIndex = null;
                var vs = 0;
                if (pOffset >= 0)
                    subrsIndex = parsePrivate(offset + pOffset, pSize, v -> vs = v);
                fdLocalSubrs.push(subrsIndex);
                fdLocalBias.push(subrsIndex != null ? biasFor(subrsIndex.count) : 0);
                defaultVsIndex.push(vs);
            }
            if (fdSelectOffset > 0)
                fdSelect = offset + fdSelectOffset;
        }
        else if (privateOffset >= 0) {
            localSubrs = parsePrivate(offset + privateOffset, privateSize, null);
            localBias = localSubrs != null ? biasFor(localSubrs.count) : 0;
        }

    }

    static inline function biasFor(count:Int):Int {
        return count < 1240 ? 107 : (count < 33900 ? 1131 : 32768);
    }

    function parsePrivate(start:Int, size:Int, onVsIndex:(Int) -> Void):CffIndex {
        var subrsOffset = -1;
        parseDict(start, start + size, function(op, ops, n) {
            if (op == 19 && n > 0)
                subrsOffset = Std.int(ops[0]);
            else if (op == 22 && n > 0 && onVsIndex != null)
                onVsIndex(Std.int(ops[0]));
        });
        if (subrsOffset > 0)
            return new CffIndex(data, start + subrsOffset, cff2);
        return null;
    }

    function parseVariationStore(pos:Int):Void {
        // CFF2 vstore: u16 length, then an ItemVariationStore
        var store = pos + 2;
        var dataCount = u16(data, store + 6);
        for (i in 0...dataCount) {
            var itemData = store + u32(data, store + 8 + i * 4);
            regionCounts.push(u16(data, itemData + 4));
        }
    }

    function parseDict(start:Int, end:Int, handler:(op:Int, ops:Array<Float>, n:Int)->Void):Void {
        var b = data;
        var p = start;
        var n = 0;
        var ops = operands;
        while (p < end) {
            var b0 = b.get(p);
            if (b0 <= 21) {
                var op = b0;
                p++;
                if (b0 == 12) {
                    op = 0x0C00 | b.get(p);
                    p++;
                }
                handler(op, ops, n);
                n = 0;
                continue;
            }
            var v:Float = 0;
            if (b0 == 28) {
                v = s16(b, p + 1);
                p += 3;
            }
            else if (b0 == 29) {
                v = u32(b, p + 1);
                p += 5;
            }
            else if (b0 == 30) {
                // Real number, packed BCD
                var s = new StringBuf();
                p++;
                var done = false;
                while (!done && p < end) {
                    var byte = b.get(p++);
                    for (k in 0...2) {
                        var nib = k == 0 ? byte >> 4 : byte & 15;
                        switch nib {
                            case 0xA: s.add('.');
                            case 0xB: s.add('E');
                            case 0xC: s.add('E-');
                            case 0xE: s.add('-');
                            case 0xF: done = true; break;
                            case 0xD:
                            default: s.add(nib);
                        }
                    }
                }
                v = Std.parseFloat(s.toString());
                if (Math.isNaN(v)) v = 0;
            }
            else if (b0 >= 32 && b0 <= 246) {
                v = b0 - 139;
                p++;
            }
            else if (b0 >= 247 && b0 <= 250) {
                v = (b0 - 247) * 256 + b.get(p + 1) + 108;
                p += 2;
            }
            else if (b0 >= 251 && b0 <= 254) {
                v = -(b0 - 251) * 256 - b.get(p + 1) - 108;
                p += 2;
            }
            else {
                p++;
                continue;
            }
            if (n < ops.length) ops[n] = v else ops.push(v);
            n++;
        }
    }

    function fdIndexOf(gid:Int):Int {
        if (fdSelect < 0)
            return 0;
        var b = data;
        var format = b.get(fdSelect);
        switch format {
            case 0:
                return b.get(fdSelect + 1 + gid);
            case 3:
                var nRanges = u16(b, fdSelect + 1);
                var lo = 0;
                var hi = nRanges - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var r = fdSelect + 3 + mid * 3;
                    var first = u16(b, r);
                    var next = u16(b, r + 3);
                    if (gid < first) hi = mid - 1;
                    else if (gid >= next) lo = mid + 1;
                    else return b.get(r + 2);
                }
                return 0;
            case 4:
                var nRanges = u32(b, fdSelect + 1);
                var lo = 0;
                var hi = nRanges - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var r = fdSelect + 5 + mid * 6;
                    var first = u32(b, r);
                    var next = u32(b, r + 6);
                    if (gid < first) hi = mid - 1;
                    else if (gid >= next) lo = mid + 1;
                    else return u16(b, r + 4);
                }
                return 0;
            default:
                return 0;
        }
    }

    /**
     * Emits the outline of `gid` into `sink`. Returns false if the glyph
     * has no outline.
     */
    public function decompose(gid:Int, sink:OutlineSink):Bool {

        if (gid < 0 || gid >= charStrings.count)
            return false;

        this.sink = sink;
        sp = 0;
        x = 0;
        y = 0;
        nStems = 0;
        haveWidth = cff2;
        open = false;
        ended = false;
        vsIndex = 0;
        contours = 0;

        if (fdLocalSubrs != null) {
            var fd = fdIndexOf(gid);
            if (fd < 0 || fd >= fdLocalSubrs.length) fd = 0;
            subrs = fdLocalSubrs[fd];
            subrBias = fdLocalBias[fd];
            vsIndex = defaultVsIndex[fd];
        }
        else {
            subrs = localSubrs;
            subrBias = localBias;
        }

        run(charStrings.start(gid), charStrings.stop(gid), 0);
        if (open) {
            sink.close();
            open = false;
        }
        this.sink = null;
        return contours > 0;

    }

    var contours:Int = 0;

    inline function push(v:Float):Void {
        if (sp < MAX_STACK)
            stack[sp++] = v;
    }

    inline function moveTo(nx:Float, ny:Float):Void {
        if (open)
            sink.close();
        x = nx;
        y = ny;
        sink.moveTo(x, y);
        open = true;
        contours++;
    }

    inline function lineTo(nx:Float, ny:Float):Void {
        x = nx;
        y = ny;
        sink.lineTo(x, y);
    }

    inline function curveTo(x1:Float, y1:Float, x2:Float, y2:Float, x3:Float, y3:Float):Void {
        x = x3;
        y = y3;
        sink.cubicTo(x1, y1, x2, y2, x3, y3);
    }

    /** Removes the optional width argument of the first stack clearing operator. */
    inline function stemWidth():Void {
        if (!haveWidth) {
            if ((sp & 1) != 0) shiftStack();
            haveWidth = true;
        }
    }

    inline function moveWidth(expected:Int):Void {
        if (!haveWidth) {
            if (sp > expected) shiftStack();
            haveWidth = true;
        }
    }

    function shiftStack():Void {
        for (i in 1...sp)
            stack[i - 1] = stack[i];
        sp--;
    }

    function run(pos:Int, end:Int, depth:Int):Void {

        var b = data;
        var s = stack;

        while (pos < end && !ended) {
            var b0 = b.get(pos);

            // Operands
            if (b0 >= 32) {
                if (b0 <= 246) {
                    push(b0 - 139);
                    pos++;
                }
                else if (b0 <= 250) {
                    push((b0 - 247) * 256 + b.get(pos + 1) + 108);
                    pos += 2;
                }
                else if (b0 <= 254) {
                    push(-(b0 - 251) * 256 - b.get(pos + 1) - 108);
                    pos += 2;
                }
                else {
                    push(u32(b, pos + 1) / 65536.0);
                    pos += 5;
                }
                continue;
            }
            if (b0 == 28) {
                push(s16(b, pos + 1));
                pos += 3;
                continue;
            }

            pos++;

            switch b0 {

                case 1 | 3 | 18 | 23: // hstem, vstem, hstemhm, vstemhm
                    stemWidth();
                    nStems += sp >> 1;
                    sp = 0;

                case 19 | 20: // hintmask, cntrmask
                    stemWidth();
                    nStems += sp >> 1;
                    sp = 0;
                    pos += (nStems + 7) >> 3;

                case 21: // rmoveto
                    moveWidth(2);
                    if (sp >= 2)
                        moveTo(x + s[sp - 2], y + s[sp - 1]);
                    sp = 0;

                case 22: // hmoveto
                    moveWidth(1);
                    if (sp >= 1)
                        moveTo(x + s[sp - 1], y);
                    sp = 0;

                case 4: // vmoveto
                    moveWidth(1);
                    if (sp >= 1)
                        moveTo(x, y + s[sp - 1]);
                    sp = 0;

                case 5: // rlineto
                    var i = 0;
                    while (i + 1 < sp) {
                        lineTo(x + s[i], y + s[i + 1]);
                        i += 2;
                    }
                    sp = 0;

                case 6 | 7: // hlineto, vlineto
                    var horizontal = b0 == 6;
                    for (i in 0...sp) {
                        if (horizontal) lineTo(x + s[i], y) else lineTo(x, y + s[i]);
                        horizontal = !horizontal;
                    }
                    sp = 0;

                case 8: // rrcurveto
                    var i = 0;
                    while (i + 5 < sp) {
                        var x1 = x + s[i];
                        var y1 = y + s[i + 1];
                        var x2 = x1 + s[i + 2];
                        var y2 = y1 + s[i + 3];
                        curveTo(x1, y1, x2, y2, x2 + s[i + 4], y2 + s[i + 5]);
                        i += 6;
                    }
                    sp = 0;

                case 24: // rcurveline
                    var i = 0;
                    while (i + 5 < sp - 2) {
                        var x1 = x + s[i];
                        var y1 = y + s[i + 1];
                        var x2 = x1 + s[i + 2];
                        var y2 = y1 + s[i + 3];
                        curveTo(x1, y1, x2, y2, x2 + s[i + 4], y2 + s[i + 5]);
                        i += 6;
                    }
                    if (i + 1 < sp)
                        lineTo(x + s[i], y + s[i + 1]);
                    sp = 0;

                case 25: // rlinecurve
                    var i = 0;
                    while (i + 1 < sp - 6) {
                        lineTo(x + s[i], y + s[i + 1]);
                        i += 2;
                    }
                    if (i + 5 < sp) {
                        var x1 = x + s[i];
                        var y1 = y + s[i + 1];
                        var x2 = x1 + s[i + 2];
                        var y2 = y1 + s[i + 3];
                        curveTo(x1, y1, x2, y2, x2 + s[i + 4], y2 + s[i + 5]);
                    }
                    sp = 0;

                case 26: // vvcurveto
                    var i = 0;
                    var dx1 = 0.0;
                    if ((sp & 1) != 0) {
                        dx1 = s[0];
                        i = 1;
                    }
                    while (i + 3 < sp) {
                        var x1 = x + dx1;
                        var y1 = y + s[i];
                        var x2 = x1 + s[i + 1];
                        var y2 = y1 + s[i + 2];
                        curveTo(x1, y1, x2, y2, x2, y2 + s[i + 3]);
                        dx1 = 0;
                        i += 4;
                    }
                    sp = 0;

                case 27: // hhcurveto
                    var i = 0;
                    var dy1 = 0.0;
                    if ((sp & 1) != 0) {
                        dy1 = s[0];
                        i = 1;
                    }
                    while (i + 3 < sp) {
                        var x1 = x + s[i];
                        var y1 = y + dy1;
                        var x2 = x1 + s[i + 1];
                        var y2 = y1 + s[i + 2];
                        curveTo(x1, y1, x2, y2, x2 + s[i + 3], y2);
                        dy1 = 0;
                        i += 4;
                    }
                    sp = 0;

                case 30 | 31: // vhcurveto, hvcurveto
                    var horizontal = b0 == 31;
                    var i = 0;
                    while (i + 3 < sp) {
                        var last = (sp - i) == 5;
                        if (horizontal) {
                            var x1 = x + s[i];
                            var y1 = y;
                            var x2 = x1 + s[i + 1];
                            var y2 = y1 + s[i + 2];
                            var y3 = y2 + s[i + 3];
                            var x3 = x2 + (last ? s[i + 4] : 0);
                            curveTo(x1, y1, x2, y2, x3, y3);
                        }
                        else {
                            var x1 = x;
                            var y1 = y + s[i];
                            var x2 = x1 + s[i + 1];
                            var y2 = y1 + s[i + 2];
                            var x3 = x2 + s[i + 3];
                            var y3 = y2 + (last ? s[i + 4] : 0);
                            curveTo(x1, y1, x2, y2, x3, y3);
                        }
                        horizontal = !horizontal;
                        i += 4;
                    }
                    sp = 0;

                case 10: // callsubr
                    if (sp > 0 && subrs != null && depth < MAX_SUBR_DEPTH) {
                        var index = Std.int(s[--sp]) + subrBias;
                        if (index >= 0 && index < subrs.count)
                            run(subrs.start(index), subrs.stop(index), depth + 1);
                    }

                case 29: // callgsubr
                    if (sp > 0 && depth < MAX_SUBR_DEPTH) {
                        var index = Std.int(s[--sp]) + globalBias;
                        if (index >= 0 && index < globalSubrs.count)
                            run(globalSubrs.start(index), globalSubrs.stop(index), depth + 1);
                    }

                case 11: // return
                    return;

                case 14: // endchar
                    if (!cff2) {
                        if (!haveWidth) {
                            if (sp == 1 || sp == 5) shiftStack();
                            haveWidth = true;
                        }
                        if (open) {
                            sink.close();
                            open = false;
                        }
                        ended = true;
                        sp = 0;
                        return;
                    }

                case 15: // vsindex (CFF2)
                    if (sp > 0) vsIndex = Std.int(s[sp - 1]);
                    sp = 0;

                case 16: // blend (CFF2): keep the default values
                    if (sp > 0) {
                        var n = Std.int(s[sp - 1]);
                        var k = (vsIndex >= 0 && vsIndex < regionCounts.length) ? regionCounts[vsIndex] : 0;
                        var total = n * (k + 1) + 1;
                        var base = sp - total;
                        if (base >= 0)
                            sp = base + n;
                        else
                            sp = 0;
                    }

                case 12:
                    var b1 = b.get(pos++);
                    escape(b1);

                default:
                    sp = 0;
            }
        }

    }

    function escape(op:Int):Void {

        var s = stack;

        switch op {

            case 35: // flex
                if (sp >= 12) {
                    var x1 = x + s[0];
                    var y1 = y + s[1];
                    var x2 = x1 + s[2];
                    var y2 = y1 + s[3];
                    var x3 = x2 + s[4];
                    var y3 = y2 + s[5];
                    curveTo(x1, y1, x2, y2, x3, y3);
                    var x4 = x3 + s[6];
                    var y4 = y3 + s[7];
                    var x5 = x4 + s[8];
                    var y5 = y4 + s[9];
                    curveTo(x4, y4, x5, y5, x5 + s[10], y5 + s[11]);
                }
                sp = 0;

            case 34: // hflex
                if (sp >= 7) {
                    var y0 = y;
                    var x1 = x + s[0];
                    var y1 = y;
                    var x2 = x1 + s[1];
                    var y2 = y1 + s[2];
                    var x3 = x2 + s[3];
                    curveTo(x1, y1, x2, y2, x3, y2);
                    var x4 = x3 + s[4];
                    var x5 = x4 + s[5];
                    curveTo(x4, y2, x5, y0, x5 + s[6], y0);
                }
                sp = 0;

            case 36: // hflex1
                if (sp >= 9) {
                    var y0 = y;
                    var x1 = x + s[0];
                    var y1 = y + s[1];
                    var x2 = x1 + s[2];
                    var y2 = y1 + s[3];
                    var x3 = x2 + s[4];
                    curveTo(x1, y1, x2, y2, x3, y2);
                    var x4 = x3 + s[5];
                    var x5 = x4 + s[6];
                    var y5 = y2 + s[7];
                    curveTo(x4, y2, x5, y5, x5 + s[8], y0);
                }
                sp = 0;

            case 37: // flex1
                if (sp >= 11) {
                    var x0 = x;
                    var y0 = y;
                    var x1 = x + s[0];
                    var y1 = y + s[1];
                    var x2 = x1 + s[2];
                    var y2 = y1 + s[3];
                    var x3 = x2 + s[4];
                    var y3 = y2 + s[5];
                    curveTo(x1, y1, x2, y2, x3, y3);
                    var x4 = x3 + s[6];
                    var y4 = y3 + s[7];
                    var x5 = x4 + s[8];
                    var y5 = y4 + s[9];
                    var dx = Math.abs(x5 - x0);
                    var dy = Math.abs(y5 - y0);
                    if (dx > dy)
                        curveTo(x4, y4, x5, y5, x5 + s[10], y0);
                    else
                        curveTo(x4, y4, x5, y5, x0, y5 + s[10]);
                }
                sp = 0;

            // Arithmetic operators (rare in practice)
            case 9: if (sp >= 1) s[sp - 1] = Math.abs(s[sp - 1]);
            case 10: if (sp >= 2) { s[sp - 2] = s[sp - 2] + s[sp - 1]; sp--; }
            case 11: if (sp >= 2) { s[sp - 2] = s[sp - 2] - s[sp - 1]; sp--; }
            case 12: if (sp >= 2) { s[sp - 2] = s[sp - 1] != 0 ? s[sp - 2] / s[sp - 1] : 0; sp--; }
            case 14: if (sp >= 1) s[sp - 1] = -s[sp - 1];
            case 18: if (sp >= 1) sp--;
            case 24: if (sp >= 2) { s[sp - 2] = s[sp - 2] * s[sp - 1]; sp--; }
            case 26: if (sp >= 1) s[sp - 1] = s[sp - 1] > 0 ? Math.sqrt(s[sp - 1]) : 0;
            case 27: if (sp >= 1) push(s[sp - 1]);
            case 28: if (sp >= 2) { var t = s[sp - 1]; s[sp - 1] = s[sp - 2]; s[sp - 2] = t; }
            case 3: if (sp >= 2) { s[sp - 2] = (s[sp - 2] != 0 && s[sp - 1] != 0) ? 1 : 0; sp--; }
            case 4: if (sp >= 2) { s[sp - 2] = (s[sp - 2] != 0 || s[sp - 1] != 0) ? 1 : 0; sp--; }
            case 5: if (sp >= 1) s[sp - 1] = s[sp - 1] == 0 ? 1 : 0;
            case 15: if (sp >= 2) { s[sp - 2] = s[sp - 2] == s[sp - 1] ? 1 : 0; sp--; }
            case 20: if (sp >= 2) { var i = Std.int(s[sp - 1]); if (i >= 0 && i < 32) transient[i] = s[sp - 2]; sp -= 2; }
            case 21: if (sp >= 1) { var i = Std.int(s[sp - 1]); s[sp - 1] = (i >= 0 && i < 32) ? transient[i] : 0; }
            case 22: if (sp >= 4) { s[sp - 4] = s[sp - 2] <= s[sp - 1] ? s[sp - 4] : s[sp - 3]; sp -= 3; }
            case 23: push(0.5);
            case 29: if (sp >= 1) { var i = Std.int(s[sp - 1]); if (i < 0) i = 0; s[sp - 1] = (sp - 2 - i >= 0) ? s[sp - 2 - i] : 0; }

            default:
                sp = 0;
        }

    }

}
