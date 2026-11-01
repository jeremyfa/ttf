// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;

/**
 * Big endian readers used by every table parser.
 *
 * Offsets are absolute positions in the font data. Values are read
 * byte by byte so that they work the same on every target and never
 * allocate. 32-bit values are returned as signed Ints (offsets in real
 * fonts stay far below 2^31).
 */
class Bin {

    public static inline function u8(b:Bytes, o:Int):Int {
        return b.get(o);
    }

    public static inline function s8(b:Bytes, o:Int):Int {
        var v = b.get(o);
        return v >= 0x80 ? v - 0x100 : v;
    }

    public static inline function u16(b:Bytes, o:Int):Int {
        return (b.get(o) << 8) | b.get(o + 1);
    }

    public static inline function s16(b:Bytes, o:Int):Int {
        var v = (b.get(o) << 8) | b.get(o + 1);
        return v >= 0x8000 ? v - 0x10000 : v;
    }

    public static inline function u24(b:Bytes, o:Int):Int {
        return (b.get(o) << 16) | (b.get(o + 1) << 8) | b.get(o + 2);
    }

    public static inline function u32(b:Bytes, o:Int):Int {
        return (b.get(o) << 24) | (b.get(o + 1) << 16) | (b.get(o + 2) << 8) | b.get(o + 3);
    }

    /** 16.16 fixed point number. */
    public static inline function fixed(b:Bytes, o:Int):Float {
        return u32(b, o) / 65536.0;
    }

    /** 2.14 fixed point number. */
    public static inline function f2dot14(b:Bytes, o:Int):Float {
        return s16(b, o) / 16384.0;
    }

    /** Reads a 4 character tag. */
    public static function tag(b:Bytes, o:Int):String {
        return String.fromCharCode(b.get(o)) + String.fromCharCode(b.get(o + 1))
            + String.fromCharCode(b.get(o + 2)) + String.fromCharCode(b.get(o + 3));
    }

    /** Packs a 4 character tag string into an Int, for fast comparisons. */
    public static function tagToInt(tag:String):Int {
        var v = 0;
        for (i in 0...4) {
            var c = i < tag.length ? StringTools.fastCodeAt(tag, i) : 32;
            v = (v << 8) | (c & 0xFF);
        }
        return v;
    }

}
