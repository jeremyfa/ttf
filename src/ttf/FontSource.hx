// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;

/**
 * Random access to the bytes of a font file, for fonts too large to be
 * read whole (Apple Color Emoji is 192 MB, almost all of it `sbix` bitmaps).
 *
 * `Font.fromSource()` reads the table directory and every table except
 * the large bitmap ones (`sbix`, `CBDT`, `EBDT`, `SVG `), then reads the
 * bitmap data of a glyph only when it is rendered.
 */
interface FontSource {

    /** Total size of the font file, in bytes. */
    var length(get, never):Int;

    /**
     * Reads `length` bytes at `offset`. Returns fewer bytes (or null) if
     * the range goes past the end of the file or cannot be read.
     */
    function read(offset:Int, length:Int):Null<Bytes>;

}

/** A `FontSource` over font data already in memory. */
class BytesFontSource implements FontSource {

    public final bytes:Bytes;

    public var length(get, never):Int;

    inline function get_length():Int {
        return bytes.length;
    }

    public function new(bytes:Bytes) {
        this.bytes = bytes;
    }

    public function read(offset:Int, length:Int):Null<Bytes> {
        if (offset < 0 || length < 0 || offset >= bytes.length)
            return null;
        if (offset + length > bytes.length)
            length = bytes.length - offset;
        return bytes.sub(offset, length);
    }

}

/**
 * A `FontSource` over a function reading a range of a file, for example
 * one that seeks into a file handle.
 */
class FunctionFontSource implements FontSource {

    final size:Int;

    final reader:(offset:Int, length:Int) -> Null<Bytes>;

    public var length(get, never):Int;

    inline function get_length():Int {
        return size;
    }

    public function new(size:Int, reader:(offset:Int, length:Int) -> Null<Bytes>) {
        this.size = size;
        this.reader = reader;
    }

    public function read(offset:Int, length:Int):Null<Bytes> {
        if (offset < 0 || length < 0 || offset >= size)
            return null;
        if (offset + length > size)
            length = size - offset;
        return reader(offset, length);
    }

}
