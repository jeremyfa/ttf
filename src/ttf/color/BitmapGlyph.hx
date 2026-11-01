// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.color;

import haxe.io.Bytes;

/**
 * The PNG image of a glyph in a bitmap strike (`sbix` or `CBDT`), with its
 * placement at the strike size (swash's `Bitmap`).
 */
class BitmapGlyph {

    /** The PNG data is `bytes[pos...pos + length]` */
    public var bytes:Bytes = null;

    public var pos:Int = 0;

    public var length:Int = 0;

    /** Size of the strike in pixels per em */
    public var ppem:Int = 0;

    /** Image size, from the PNG header */
    public var width:Int = 0;

    public var height:Int = 0;

    /** x of the left edge relative to the glyph origin, in strike pixels */
    public var left:Int = 0;

    /** y of the top edge relative to the baseline (y up), in strike pixels */
    public var top:Int = 0;

    /** True if the image must be mirrored horizontally (`sbix` `flip` glyphs) */
    public var flip:Bool = false;

    public function new() {}

}
