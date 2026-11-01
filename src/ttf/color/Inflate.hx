// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.color;

import haxe.io.Bytes;

/**
 * Decompression of DEFLATE streams (RFC 1951), with or without the zlib
 * wrapper (RFC 1950), for the PNG images of color fonts. Pure Haxe, no
 * dependency.
 *
 * Use one instance per thread: its tables and output buffer are reused.
 */
class Inflate {

    // Code lengths of the fixed Huffman codes and the order of the code length codes
    static final LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
    static final LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
    static final DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
    static final DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
    static final CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

    var input:Bytes;
    var inPos:Int = 0;
    var inEnd:Int = 0;
    var bitBuf:Int = 0;
    var bitCount:Int = 0;

    var out:Bytes;
    var outLen:Int = 0;

    // Huffman tables: counts per length and symbols sorted by code
    final litCounts = new haxe.ds.Vector<Int>(16);
    final litSymbols = new haxe.ds.Vector<Int>(288);
    final distCounts = new haxe.ds.Vector<Int>(16);
    final distSymbols = new haxe.ds.Vector<Int>(32);
    final lengths = new haxe.ds.Vector<Int>(340);
    final offs = new haxe.ds.Vector<Int>(16);

    public function new() {
        out = Bytes.alloc(4096);
    }

    /**
     * Decompresses a zlib stream (`zlib` true, PNG's `IDAT` data) or a raw
     * DEFLATE stream from `data[pos...pos + len]`. `expectedSize` sizes the
     * output buffer (it grows if needed). Returns the decompressed bytes,
     * or null if the stream is invalid.
     */
    public function run(data:Bytes, pos:Int, len:Int, zlib:Bool = true, expectedSize:Int = 0):Null<Bytes> {
        input = data;
        inPos = pos;
        inEnd = pos + len;
        bitBuf = 0;
        bitCount = 0;
        outLen = 0;
        if (expectedSize > out.length)
            out = Bytes.alloc(expectedSize);
        if (zlib) {
            if (len < 2)
                return null;
            var cmf = data.get(inPos);
            var flg = data.get(inPos + 1);
            if ((cmf & 15) != 8 || ((cmf << 8) | flg) % 31 != 0 || (flg & 0x20) != 0)
                return null;
            inPos += 2;
        }
        try {
            if (!inflate())
                return null;
        }
        catch (e:InflateError) {
            return null;
        }
        input = null;
        return out.sub(0, outLen);
    }

    inline function needBits(n:Int):Void {
        while (bitCount < n) {
            if (inPos >= inEnd)
                throw InflateError.Eof;
            bitBuf |= input.get(inPos++) << bitCount;
            bitCount += 8;
        }
    }

    inline function bits(n:Int):Int {
        needBits(n);
        var v = bitBuf & ((1 << n) - 1);
        bitBuf >>>= n;
        bitCount -= n;
        return v;
    }

    inline function ensure(extra:Int):Void {
        if (outLen + extra > out.length) {
            var size = out.length * 2;
            while (size < outLen + extra)
                size *= 2;
            var bigger = Bytes.alloc(size);
            bigger.blit(0, out, 0, outLen);
            out = bigger;
        }
    }

    function inflate():Bool {
        var last = false;
        while (!last) {
            last = bits(1) == 1;
            var type = bits(2);
            switch type {
                case 0:
                    // Stored block
                    bitBuf = 0;
                    bitCount = 0;
                    if (inPos + 4 > inEnd)
                        return false;
                    var len = input.get(inPos) | (input.get(inPos + 1) << 8);
                    var nlen = input.get(inPos + 2) | (input.get(inPos + 3) << 8);
                    inPos += 4;
                    if (len != (~nlen & 0xFFFF) || inPos + len > inEnd)
                        return false;
                    ensure(len);
                    out.blit(outLen, input, inPos, len);
                    outLen += len;
                    inPos += len;
                case 1:
                    fixedTables();
                    if (!codes())
                        return false;
                case 2:
                    if (!dynamicTables())
                        return false;
                    if (!codes())
                        return false;
                case _:
                    return false;
            }
        }
        return true;
    }

    /** Builds canonical Huffman tables (counts per length, sorted symbols). */
    function build(counts:haxe.ds.Vector<Int>, symbols:haxe.ds.Vector<Int>, start:Int, n:Int):Bool {
        for (i in 0...16)
            counts[i] = 0;
        for (i in 0...n)
            counts[lengths[start + i]]++;
        if (counts[0] == n)
            return true;
        var left = 1;
        for (len in 1...16) {
            left <<= 1;
            left -= counts[len];
            if (left < 0)
                return false;
        }
        offs[1] = 0;
        for (len in 1...15)
            offs[len + 1] = offs[len] + counts[len];
        for (i in 0...n) {
            var l = lengths[start + i];
            if (l != 0)
                symbols[offs[l]++] = i;
        }
        return true;
    }

    function fixedTables():Void {
        for (i in 0...144) lengths[i] = 8;
        for (i in 144...256) lengths[i] = 9;
        for (i in 256...280) lengths[i] = 7;
        for (i in 280...288) lengths[i] = 8;
        build(litCounts, litSymbols, 0, 288);
        for (i in 0...30) lengths[i] = 5;
        build(distCounts, distSymbols, 0, 30);
    }

    function dynamicTables():Bool {
        var nlen = bits(5) + 257;
        var ndist = bits(5) + 1;
        var ncode = bits(4) + 4;
        if (nlen > 286 || ndist > 30)
            return false;
        for (i in 0...19)
            lengths[i] = 0;
        for (i in 0...ncode)
            lengths[CL_ORDER[i]] = bits(3);
        // The code length code reuses the literal table
        if (!build(litCounts, litSymbols, 0, 19))
            return false;
        var index = 0;
        var total = nlen + ndist;
        // Code lengths are stored after the 19 code length lengths
        var base = 19;
        while (index < total) {
            var symbol = decode(litCounts, litSymbols);
            if (symbol < 16) {
                lengths[base + index++] = symbol;
            }
            else {
                var len = 0;
                var repeat = 0;
                if (symbol == 16) {
                    if (index == 0)
                        return false;
                    len = lengths[base + index - 1];
                    repeat = 3 + bits(2);
                }
                else if (symbol == 17) {
                    repeat = 3 + bits(3);
                }
                else {
                    repeat = 11 + bits(7);
                }
                if (index + repeat > total)
                    return false;
                for (_ in 0...repeat)
                    lengths[base + index++] = len;
            }
        }
        if (lengths[base + 256] == 0)
            return false;
        // Move the lengths to the start for `build`
        for (i in 0...total)
            lengths[i] = lengths[base + i];
        if (!build(litCounts, litSymbols, 0, nlen))
            return false;
        if (!build(distCounts, distSymbols, nlen, ndist))
            return false;
        return true;
    }

    /** Decodes one symbol, reading the code bit by bit (canonical codes). */
    inline function decode(counts:haxe.ds.Vector<Int>, symbols:haxe.ds.Vector<Int>):Int {
        var code = 0;
        var first = 0;
        var index = 0;
        var result = -1;
        var len = 1;
        while (len < 16) {
            code |= bits(1);
            var count = counts[len];
            if (code - count < first) {
                result = symbols[index + (code - first)];
                break;
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
            len++;
        }
        if (result < 0)
            throw InflateError.BadCode;
        return result;
    }

    function codes():Bool {
        while (true) {
            var symbol = decode(litCounts, litSymbols);
            if (symbol < 256) {
                ensure(1);
                out.set(outLen++, symbol);
            }
            else if (symbol == 256) {
                return true;
            }
            else {
                symbol -= 257;
                if (symbol >= 29)
                    return false;
                var len = LENGTH_BASE[symbol] + bits(LENGTH_EXTRA[symbol]);
                var ds = decode(distCounts, distSymbols);
                if (ds >= 30)
                    return false;
                var dist = DIST_BASE[ds] + bits(DIST_EXTRA[ds]);
                if (dist > outLen)
                    return false;
                ensure(len);
                var from = outLen - dist;
                if (dist >= len) {
                    out.blit(outLen, out, from, len);
                    outLen += len;
                }
                else {
                    for (i in 0...len)
                        out.set(outLen++, out.get(from + i));
                }
            }
        }
    }

}

private enum InflateError {
    Eof;
    BadCode;
}
