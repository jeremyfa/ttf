// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Glyph definition table (`GDEF`): glyph classes, mark attachment classes
 * and mark glyph sets, used to skip glyphs according to lookup flags.
 */
class Gdef {

    public static inline var BASE = 1;
    public static inline var LIGATURE = 2;
    public static inline var MARK = 3;
    public static inline var COMPONENT = 4;

    /**
     * Not a GDEF class: default ignorable characters (joiners, directional
     * marks...) not mapped by the font. Skipped by every lookup, rendered
     * as an invisible space.
     */
    public static inline var HIDDEN = 5;

    var data:Bytes;

    var glyphClassDef:Int = -1;

    var markAttachClassDef:Int = -1;

    var markGlyphSets:Int = -1;

    public var hasGlyphClasses(default, null):Bool = false;

    public function new(data:Bytes, offset:Int) {
        this.data = data;
        if (offset < 0)
            return;
        var minor = u16(data, offset + 2);
        var o = u16(data, offset + 4);
        if (o != 0) {
            glyphClassDef = offset + o;
            hasGlyphClasses = true;
        }
        o = u16(data, offset + 10);
        if (o != 0)
            markAttachClassDef = offset + o;
        if (minor >= 2) {
            o = u16(data, offset + 12);
            if (o != 0)
                markGlyphSets = offset + o;
        }
    }

    /** Glyph class: 0 (unknown), BASE, LIGATURE, MARK or COMPONENT. */
    public inline function glyphClass(gid:Int):Int {
        return glyphClassDef > 0 ? OtCommon.classOf(data, glyphClassDef, gid) : 0;
    }

    public inline function markAttachClass(gid:Int):Int {
        return markAttachClassDef > 0 ? OtCommon.classOf(data, markAttachClassDef, gid) : 0;
    }

    /** Returns true if `gid` belongs to the mark glyph set `set`. */
    public function inMarkSet(set:Int, gid:Int):Bool {
        if (markGlyphSets < 0)
            return false;
        var count = u16(data, markGlyphSets + 2);
        if (set < 0 || set >= count)
            return false;
        var cov = markGlyphSets + u32(data, markGlyphSets + 4 + set * 4);
        return OtCommon.coverageIndex(data, cov, gid) >= 0;
    }

}
