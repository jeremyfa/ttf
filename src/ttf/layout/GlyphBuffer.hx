// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

/**
 * The glyph sequence being shaped: glyph ids, clusters (UTF-8 byte offsets
 * of the source text), glyph classes and positions in font units.
 *
 * Arrays only grow: the buffer is meant to be reused between calls.
 */
class GlyphBuffer {

    public var length:Int = 0;

    public var glyphs:Array<Int> = [];

    /** UTF-8 byte offset of the first character that produced each glyph. */
    public var clusters:Array<Int> = [];

    /** Glyph class (see `Gdef`), 0 if unknown. */
    public var classes:Array<Int> = [];

    public var xAdvance:Array<Int> = [];

    public var yAdvance:Array<Int> = [];

    public var xOffset:Array<Int> = [];

    public var yOffset:Array<Int> = [];

    /** Index of the glyph a mark is attached to, or -1. */
    public var attachTo:Array<Int> = [];

    public function new() {}

    public function clear():Void {
        length = 0;
    }

    public function push(gid:Int, cluster:Int, glyphClass:Int):Void {
        var i = length;
        if (i < glyphs.length) {
            glyphs[i] = gid;
            clusters[i] = cluster;
            classes[i] = glyphClass;
            xAdvance[i] = 0;
            yAdvance[i] = 0;
            xOffset[i] = 0;
            yOffset[i] = 0;
            attachTo[i] = -1;
        }
        else {
            glyphs.push(gid);
            clusters.push(cluster);
            classes.push(glyphClass);
            xAdvance.push(0);
            yAdvance.push(0);
            xOffset.push(0);
            yOffset.push(0);
            attachTo.push(-1);
        }
        length = i + 1;
    }

    /** Removes the glyph at `index`. */
    public function remove(index:Int):Void {
        var n = length;
        for (k in index...n - 1) {
            glyphs[k] = glyphs[k + 1];
            clusters[k] = clusters[k + 1];
            classes[k] = classes[k + 1];
            xAdvance[k] = xAdvance[k + 1];
            yAdvance[k] = yAdvance[k + 1];
            xOffset[k] = xOffset[k + 1];
            yOffset[k] = yOffset[k + 1];
            attachTo[k] = attachTo[k + 1];
        }
        length = n - 1;
    }

    /** Inserts a glyph at `index` (shifting the following glyphs). */
    public function insert(index:Int, gid:Int, cluster:Int, glyphClass:Int):Void {
        push(0, 0, 0);
        var k = length - 1;
        while (k > index) {
            glyphs[k] = glyphs[k - 1];
            clusters[k] = clusters[k - 1];
            classes[k] = classes[k - 1];
            xAdvance[k] = xAdvance[k - 1];
            yAdvance[k] = yAdvance[k - 1];
            xOffset[k] = xOffset[k - 1];
            yOffset[k] = yOffset[k - 1];
            attachTo[k] = attachTo[k - 1];
            k--;
        }
        glyphs[index] = gid;
        clusters[index] = cluster;
        classes[index] = glyphClass;
        xAdvance[index] = 0;
        yAdvance[index] = 0;
        xOffset[index] = 0;
        yOffset[index] = 0;
        attachTo[index] = -1;
    }

}
