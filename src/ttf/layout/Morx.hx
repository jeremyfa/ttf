// Ported from HarfBuzz 10: src/hb-aat-layout-morx-table.hh (RearrangementSubtable
// left out, ContextualSubtable, LigatureSubtable, NoncontextualSubtable, Chain),
// src/hb-aat-layout-common.hh (Lookup, StateTable, StateTableDriver)
// Original code Copyright 2017-2018 Google, Inc., licensed under the "Old MIT" license.
// Modified: translated from C++ to Haxe, part of the ttf library for Ceramic.
// Works in place on a `GlyphBuffer` (these subtables never change its length;
// deleted glyphs are marked and removed at the end); insertion and
// rearrangement subtables are skipped.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Apple's extended glyph metamorphosis table (`morx`), the AAT equivalent
 * of `GSUB`: Apple Color Emoji forms its ZWJ sequences, skin tones, flags
 * and keycaps with it.
 *
 * Supported: the chains with their default feature flags, noncontextual
 * (type 4), contextual (type 1) and ligature (type 2) subtables, the
 * subtables of Apple Color Emoji. Insertion (type 5) and rearrangement
 * (type 0) subtables are skipped (Apple Color Emoji only uses them with
 * features off by default).
 */
class Morx {

    final data:Bytes;

    final subtables:Array<Int> = [];

    final types:Array<Int> = [];

    /** A glyph removed by a ligature, until the end of the table */
    public static inline final DELETED = 0xFFFF;

    // Classes of the extended state tables
    static inline final END_OF_TEXT = 0;
    static inline final OUT_OF_BOUNDS = 1;
    static inline final DELETED_GLYPH = 2;

    public function new(data:Bytes, offset:Int, length:Int) {
        this.data = data;
        var end = offset + length;
        if (length < 8 || u16(data, offset) < 2)
            return;
        var nChains = u32(data, offset + 4);
        var chain = offset + 8;
        for (c in 0...nChains) {
            if (chain + 16 > end)
                break;
            var defaultFlags = u32(data, chain);
            var chainLength = u32(data, chain + 4);
            var nFeatures = u32(data, chain + 8);
            var nSubtables = u32(data, chain + 12);
            var sub = chain + 16 + nFeatures * 12;
            for (s in 0...nSubtables) {
                if (sub + 12 > end)
                    break;
                var subLength = u32(data, sub);
                var coverage = u32(data, sub + 4);
                var flags = u32(data, sub + 8);
                var type = coverage & 0xFF;
                // Horizontal text only, subtables enabled by default
                if ((coverage & 0x80000000) == 0 || (coverage & 0x20000000) != 0) {
                    if ((flags & defaultFlags) != 0 && (type == 1 || type == 2 || type == 4)) {
                        subtables.push(sub + 12);
                        types.push(type);
                    }
                }
                if (subLength <= 0)
                    break;
                sub += subLength;
            }
            if (chainLength <= 0)
                break;
            chain += chainLength;
        }
    }

    public var isEmpty(get, never):Bool;

    inline function get_isEmpty():Bool {
        return subtables.length == 0;
    }

    /** Glyphs deleted as ligature components (1) during `apply()` */
    var ligated:Bytes = Bytes.alloc(64);

    var original:Array<Int> = [];

    /**
     * Applies the enabled subtables to the glyphs of `buf`, then removes the
     * deleted glyphs (a ligature keeps the cluster of its first component).
     * `numGlyphs` is the number of glyphs of the font.
     *
     * Default ignorable characters (`Gdef.HIDDEN` glyphs, like variation
     * selectors) that a subtable deletes without making them part of a
     * ligature stay as hidden glyphs, and hidden glyphs that a subtable
     * replaces become visible: what HarfBuzz gives (`hb_ot_hide_default_ignorables`
     * only hides the characters that were not substituted).
     */
    public function apply(buf:GlyphBuffer, numGlyphs:Int):Void {
        var len = buf.length;
        if (ligated.length < len)
            ligated = Bytes.alloc(len * 2);
        ligated.fill(0, len, 0);
        original.resize(0);
        for (i in 0...len)
            original.push(buf.glyphs[i]);
        for (i in 0...subtables.length) {
            switch types[i] {
                case 4: noncontextual(buf, subtables[i], numGlyphs);
                case 1: contextual(buf, subtables[i], numGlyphs);
                case 2: ligature(buf, subtables[i], numGlyphs);
                case _:
            }
        }
        var write = 0;
        for (i in 0...len) {
            var g = buf.glyphs[i];
            var hidden = buf.classes[i] == Gdef.HIDDEN;
            if (g == DELETED) {
                if (!hidden || ligated.get(i) != 0)
                    continue;
                // Still a hidden character: the shaper draws it as an empty space
                g = original[i];
            }
            else if (hidden && g != original[i]) {
                buf.classes[i] = Gdef.BASE;
            }
            if (write != i) {
                buf.glyphs[write] = g;
                buf.clusters[write] = buf.clusters[i];
                buf.classes[write] = buf.classes[i];
                buf.xAdvance[write] = buf.xAdvance[i];
                buf.yAdvance[write] = buf.yAdvance[i];
                buf.xOffset[write] = buf.xOffset[i];
                buf.yOffset[write] = buf.yOffset[i];
                buf.attachTo[write] = buf.attachTo[i];
            }
            else {
                buf.glyphs[write] = g;
            }
            write++;
        }
        buf.length = write;
    }

/// Lookup tables

    /** Value of a glyph in an AAT lookup table, or -1 (`Lookup<HBUINT16>::get_value`) */
    function lookup(table:Int, gid:Int, numGlyphs:Int):Int {
        var d = data;
        switch u16(d, table) {
            case 0:
                return gid < numGlyphs ? u16(d, table + 2 + gid * 2) : -1;
            case 2:
                var unitSize = u16(d, table + 2);
                var n = searchUnits(table, unitSize);
                var base = table + 12;
                var lo = 0;
                var hi = n - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var rec = base + mid * unitSize;
                    if (gid < u16(d, rec + 2))
                        hi = mid - 1;
                    else if (gid > u16(d, rec))
                        lo = mid + 1;
                    else
                        return u16(d, rec + 4);
                }
                return -1;
            case 4:
                var unitSize = u16(d, table + 2);
                var n = searchUnits(table, unitSize);
                var base = table + 12;
                var lo = 0;
                var hi = n - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var rec = base + mid * unitSize;
                    var first = u16(d, rec + 2);
                    if (gid < first)
                        hi = mid - 1;
                    else if (gid > u16(d, rec))
                        lo = mid + 1;
                    else
                        return u16(d, table + u16(d, rec + 4) + (gid - first) * 2);
                }
                return -1;
            case 6:
                var unitSize = u16(d, table + 2);
                var n = searchUnits(table, unitSize);
                var base = table + 12;
                var lo = 0;
                var hi = n - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    var rec = base + mid * unitSize;
                    var g = u16(d, rec);
                    if (gid < g)
                        hi = mid - 1;
                    else if (gid > g)
                        lo = mid + 1;
                    else
                        return u16(d, rec + 2);
                }
                return -1;
            case 8:
                var first = u16(d, table + 2);
                var count = u16(d, table + 4);
                return gid >= first && gid < first + count ? u16(d, table + 6 + (gid - first) * 2) : -1;
            case 10:
                var unitSize = u16(d, table + 2);
                var first = u16(d, table + 4);
                var count = u16(d, table + 6);
                if (gid < first || gid >= first + count)
                    return -1;
                var p = table + 8 + (gid - first) * unitSize;
                return switch unitSize {
                    case 1: d.get(p);
                    case 2: u16(d, p);
                    case 4: u32(d, p);
                    case _: -1;
                }
            case _:
                return -1;
        }
    }

    /** Number of units of a binary search table, without the 0xFFFF terminator */
    function searchUnits(table:Int, unitSize:Int):Int {
        var n = u16(data, table + 4);
        if (n > 0 && u16(data, table + 12 + (n - 1) * unitSize) == 0xFFFF)
            n--;
        return n;
    }

/// State tables

    /** Class of a glyph in an extended state table */
    inline function glyphClass(classTable:Int, gid:Int, numGlyphs:Int):Int {
        if (gid == DELETED)
            return DELETED_GLYPH;
        var c = lookup(classTable, gid, numGlyphs);
        return c < 0 ? OUT_OF_BOUNDS : c;
    }

    function noncontextual(buf:GlyphBuffer, sub:Int, numGlyphs:Int):Void {
        for (i in 0...buf.length) {
            var g = buf.glyphs[i];
            if (g == DELETED)
                continue;
            var r = lookup(sub, g, numGlyphs);
            if (r >= 0)
                buf.glyphs[i] = r;
        }
    }

    /**
     * Runs an extended state machine (HarfBuzz `StateTableDriver::drive`),
     * calling `transition(entry, idx)` for each step. Returns nothing; the
     * transition returns false to stop.
     */
    inline function drive(buf:GlyphBuffer, sub:Int, numGlyphs:Int, entrySize:Int, transition:(entry:Int, idx:Int) -> Void):Void {
        var d = data;
        var nClasses = u32(d, sub);
        var classTable = sub + u32(d, sub + 4);
        var stateArray = sub + u32(d, sub + 8);
        var entryTable = sub + u32(d, sub + 12);
        var state = 0;
        var idx = 0;
        var len = buf.length;
        // Bound on the steps that do not advance (HarfBuzz's max_ops)
        var ops = len * 16 + 64;
        while (true) {
            var klass = idx < len ? glyphClass(classTable, buf.glyphs[idx], numGlyphs) : END_OF_TEXT;
            if (klass >= nClasses)
                klass = OUT_OF_BOUNDS;
            var entryIndex = u16(d, stateArray + (state * nClasses + klass) * 2);
            var entry = entryTable + entryIndex * entrySize;
            var newState = u16(d, entry);
            var flags = u16(d, entry + 2);
            transition(entry, idx);
            state = newState;
            if (idx >= len)
                break;
            if ((flags & 0x4000) == 0 || --ops <= 0)
                idx++;
        }
    }

    function contextual(buf:GlyphBuffer, sub:Int, numGlyphs:Int):Void {
        var d = data;
        var substitutions = sub + u32(d, sub + 16);
        var mark = 0;
        var markSet = false;
        var len = buf.length;
        drive(buf, sub, numGlyphs, 8, (entry, idx) -> {
            var flags = u16(d, entry + 2);
            var markIndex = u16(d, entry + 4);
            var currentIndex = u16(d, entry + 6);
            // Nothing to substitute at the end of text without a mark
            if (idx >= len && !markSet)
                return;
            if (markIndex != 0xFFFF && mark < len) {
                var table = substitutions + u32(d, substitutions + markIndex * 4);
                var g = buf.glyphs[mark];
                if (g != DELETED) {
                    var r = lookup(table, g, numGlyphs);
                    if (r >= 0)
                        buf.glyphs[mark] = r;
                }
            }
            if (currentIndex != 0xFFFF) {
                var i = idx < len ? idx : len - 1;
                if (i >= 0) {
                    var table = substitutions + u32(d, substitutions + currentIndex * 4);
                    var g = buf.glyphs[i];
                    if (g != DELETED) {
                        var r = lookup(table, g, numGlyphs);
                        if (r >= 0)
                            buf.glyphs[i] = r;
                    }
                }
            }
            if ((flags & 0x8000) != 0) {
                markSet = true;
                mark = idx;
            }
        });
    }

    /** Size of the component stack (HarfBuzz's `match_positions`) */
    static inline final STACK = 64;

    final matchPositions = new haxe.ds.Vector<Int>(STACK);

    function ligature(buf:GlyphBuffer, sub:Int, numGlyphs:Int):Void {
        var d = data;
        var ligActions = sub + u32(d, sub + 16);
        var components = sub + u32(d, sub + 20);
        var ligatures = sub + u32(d, sub + 24);
        var len = buf.length;
        var matchLength = 0;
        var positions = matchPositions;
        drive(buf, sub, numGlyphs, 6, (entry, idx) -> {
            var flags = u16(d, entry + 2);
            if ((flags & 0x8000) != 0) {
                // SetComponent: never mark the same index twice
                if (matchLength > 0 && positions[(matchLength - 1) % STACK] == idx)
                    matchLength--;
                positions[matchLength++ % STACK] = idx;
            }
            if ((flags & 0x2000) == 0)
                return;
            // PerformAction
            if (matchLength == 0 || idx >= len)
                return;
            var action = ligActions + u16(d, entry + 4) * 4;
            var cursor = matchLength;
            var ligatureIndex = 0;
            while (true) {
                if (cursor == 0) {
                    // Stack underflow
                    matchLength = 0;
                    break;
                }
                cursor--;
                var pos = positions[cursor % STACK];
                var a = u32(d, action);
                var offset = a & 0x3FFFFFFF;
                if ((offset & 0x20000000) != 0)
                    offset |= 0xC0000000;
                var g = pos < len ? buf.glyphs[pos] : DELETED;
                var componentIndex = g + offset;
                ligatureIndex += u16(d, components + componentIndex * 2);
                if ((a & 0xC0000000) != 0) {
                    // Store or Last: the ligature replaces this component, the later ones are deleted
                    var lig = u16(d, ligatures + ligatureIndex * 2);
                    if (pos < len)
                        buf.glyphs[pos] = lig;
                    while (matchLength - 1 > cursor) {
                        matchLength--;
                        var p = positions[matchLength % STACK];
                        if (p < len) {
                            buf.glyphs[p] = DELETED;
                            ligated.set(p, 1);
                        }
                    }
                }
                action += 4;
                if ((a & 0x80000000) != 0)
                    break;
            }
        });
    }

}
