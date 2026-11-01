// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Glyph substitution table (`GSUB`).
 *
 * Supported lookup types: 1 (single), 2 (multiple), 3 (alternate, the
 * first alternate is used), 4 (ligature), 5 (context), 6 (chained context)
 * and 7 (extension). Type 8 (reverse chained single) is ignored.
 *
 * Lookups are applied one after the other in lookup list order, each
 * across the whole buffer, like HarfBuzz does for simple scripts.
 */
class Gsub extends OtLayout {

    // Ligature matching scratch
    var ligPositions:Array<Int> = [];

    public function new(data:Bytes, offset:Int, gdef:Gdef, numGlyphs:Int) {
        super(data, offset, gdef, numGlyphs);
    }

    override function extensionType():Int {
        return 7;
    }

    override function firstCoverage(type:Int, sub:Int):Int {
        if (type == 5)
            return contextFirstCoverage(sub, false);
        if (type == 6)
            return contextFirstCoverage(sub, true);
        if (type >= 1 && type <= 4)
            return sub + ttf.Bin.u16(data, sub + 2);
        return -1;
    }

    /**
     * Applies the given lookups (sorted indices, see `lookupsFor()`).
     */
    public function apply(buf:GlyphBuffer, lookups:Array<Int>):Void {
        for (li in 0...lookups.length) {
            var lookupIndex = lookups[li];
            var lookup = lookupOffset(lookupIndex);
            var type = lookupType(lookup);
            if (type == 8)
                continue;
            var flag = lookupFlag(lookup);
            var markSet = markFilteringSet(lookup);
            var d = digest(lookupIndex);
            var i = 0;
            while (i < buf.length) {
                var g = buf.glyphs[i];
                if (g >= d.length || d.get(g) == 0 || skip(buf, i, flag, markSet)) {
                    i++;
                    continue;
                }
                var next = applyLookup(lookup, buf, i, flag, markSet);
                i = next >= 0 ? next : i + 1;
            }
        }
    }

    override function applyNested(lookupIndex:Int, buf:GlyphBuffer, index:Int):Bool {
        if (lookupIndex >= lookupCount)
            return false;
        var lookup = lookupOffset(lookupIndex);
        var flag = lookupFlag(lookup);
        var markSet = markFilteringSet(lookup);
        if (skip(buf, index, flag, markSet))
            return false;
        return applyLookup(lookup, buf, index, flag, markSet) >= 0;
    }

    /**
     * Tries every subtable of a lookup at `index`. Returns the index where
     * the next attempt should start, or -1 if nothing applied.
     */
    function applyLookup(lookup:Int, buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {
        var type = lookupType(lookup);
        var count = subtableCount(lookup);
        for (s in 0...count) {
            var sub = subtableOffset(lookup, s);
            var t = type;
            if (t == 7) {
                t = u16(data, sub + 2);
                sub = sub + u32(data, sub + 4);
            }
            var result = applySubtable(t, sub, buf, index, flag, markSet);
            if (result >= 0)
                return result;
        }
        return -1;
    }

    inline function classOfGlyph(gid:Int):Int {
        return gdef != null ? gdef.glyphClass(gid) : 0;
    }

    function applySubtable(type:Int, sub:Int, buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {

        var b = data;
        var gid = buf.glyphs[index];

        switch type {

            case 1: // Single
                var format = u16(b, sub);
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0)
                    return -1;
                var newGid:Int;
                if (format == 1) {
                    newGid = (gid + s16(b, sub + 4)) & 0xFFFF;
                }
                else {
                    if (cov >= u16(b, sub + 4))
                        return -1;
                    newGid = u16(b, sub + 6 + cov * 2);
                }
                buf.glyphs[index] = newGid;
                buf.classes[index] = classOfGlyph(newGid);
                return index + 1;

            case 2: // Multiple
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0 || cov >= u16(b, sub + 4))
                    return -1;
                var seq = sub + u16(b, sub + 6 + cov * 2);
                var n = u16(b, seq);
                var cluster = buf.clusters[index];
                if (n == 0) {
                    buf.remove(index);
                    return index;
                }
                var first = u16(b, seq + 2);
                buf.glyphs[index] = first;
                buf.classes[index] = classOfGlyph(first);
                for (k in 1...n) {
                    var g = u16(b, seq + 2 + k * 2);
                    buf.insert(index + k, g, cluster, classOfGlyph(g));
                }
                return index + n;

            case 3: // Alternate (first alternate)
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0 || cov >= u16(b, sub + 4))
                    return -1;
                var set = sub + u16(b, sub + 6 + cov * 2);
                if (u16(b, set) == 0)
                    return -1;
                var g = u16(b, set + 2);
                buf.glyphs[index] = g;
                buf.classes[index] = classOfGlyph(g);
                return index + 1;

            case 4: // Ligature
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0 || cov >= u16(b, sub + 4))
                    return -1;
                var ligSet = sub + u16(b, sub + 6 + cov * 2);
                var ligCount = u16(b, ligSet);
                var positions = ligPositions;
                for (l in 0...ligCount) {
                    var lig = ligSet + u16(b, ligSet + 2 + l * 2);
                    var ligGlyph = u16(b, lig);
                    var compCount = u16(b, lig + 2);
                    var pos = index;
                    var matched = true;
                    for (k in 1...compCount) {
                        pos = nextIndex(buf, pos, flag, markSet);
                        if (pos < 0 || buf.glyphs[pos] != u16(b, lig + 4 + (k - 1) * 2)) {
                            matched = false;
                            break;
                        }
                        if (k - 1 < positions.length) positions[k - 1] = pos else positions.push(pos);
                    }
                    if (!matched)
                        continue;
                    // Merge clusters of everything covered by the ligature
                    var cluster = buf.clusters[index];
                    var last = compCount > 1 ? positions[compCount - 2] : index;
                    for (k in index + 1...last + 1) {
                        if (buf.clusters[k] < cluster) cluster = buf.clusters[k];
                    }
                    for (k in index...last + 1)
                        buf.clusters[k] = cluster;
                    buf.glyphs[index] = ligGlyph;
                    buf.classes[index] = classOfGlyph(ligGlyph);
                    // Remove components (from the end to keep positions valid)
                    var k = compCount - 2;
                    while (k >= 0) {
                        buf.remove(positions[k]);
                        k--;
                    }
                    return index + 1;
                }
                return -1;

            case 5:
                return applyContext(buf, index, sub, false, flag, markSet);

            case 6:
                return applyContext(buf, index, sub, true, flag, markSet);

            default:
                return -1;
        }

    }

}
