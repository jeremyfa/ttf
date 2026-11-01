// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Glyph positioning table (`GPOS`).
 *
 * Supported lookup types: 1 (single adjustment), 2 (pair adjustment,
 * formats 1 and 2), 4 (mark to base), 6 (mark to mark), 7 (context),
 * 8 (chained context) and 9 (extension). Device tables and variation
 * deltas are ignored. Types 3 (cursive) and 5 (mark to ligature) are not
 * supported yet.
 *
 * Values are accumulated in the buffer in font units. Attached marks get
 * an offset relative to the glyph they attach to (see `GlyphBuffer.attachTo`).
 */
class Gpos extends OtLayout {

    public function new(data:Bytes, offset:Int, gdef:Gdef, numGlyphs:Int) {
        super(data, offset, gdef, numGlyphs);
    }

    override function extensionType():Int {
        return 9;
    }

    override function firstCoverage(type:Int, sub:Int):Int {
        if (type == 7)
            return contextFirstCoverage(sub, false);
        if (type == 8)
            return contextFirstCoverage(sub, true);
        if (type >= 1 && type <= 6)
            return sub + ttf.Bin.u16(data, sub + 2);
        return -1;
    }

    /**
     * Applies the given lookups (sorted indices, see `lookupsFor()`).
     */
    public function apply(buf:GlyphBuffer, lookups:Array<Int>):Void {
        for (li in 0...lookups.length) {
            var lookup = lookupOffset(lookups[li]);
            var flag = lookupFlag(lookup);
            var markSet = markFilteringSet(lookup);
            var d = digest(lookups[li]);
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

    function applyLookup(lookup:Int, buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {
        var type = lookupType(lookup);
        var count = subtableCount(lookup);
        for (s in 0...count) {
            var sub = subtableOffset(lookup, s);
            var t = type;
            if (t == 9) {
                t = u16(data, sub + 2);
                sub = sub + u32(data, sub + 4);
            }
            var result = applySubtable(t, sub, buf, index, flag, markSet);
            if (result >= 0)
                return result;
        }
        return -1;
    }

    static inline function valueSize(format:Int):Int {
        var n = 0;
        var f = format & 0xFF;
        while (f != 0) {
            n += f & 1;
            f >>= 1;
        }
        return n * 2;
    }

    /** Adds a value record to the glyph at `index`. */
    function applyValue(buf:GlyphBuffer, index:Int, format:Int, pos:Int):Void {
        var b = data;
        if ((format & 0x1) != 0) {
            buf.xOffset[index] += s16(b, pos);
            pos += 2;
        }
        if ((format & 0x2) != 0) {
            buf.yOffset[index] += s16(b, pos);
            pos += 2;
        }
        if ((format & 0x4) != 0) {
            buf.xAdvance[index] += s16(b, pos);
            pos += 2;
        }
        if ((format & 0x8) != 0) {
            buf.yAdvance[index] += s16(b, pos);
        }
    }

    function applySubtable(type:Int, sub:Int, buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {

        var b = data;
        var gid = buf.glyphs[index];

        switch type {

            case 1: // Single adjustment
                var format = u16(b, sub);
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0)
                    return -1;
                var valueFormat = u16(b, sub + 4);
                if (format == 1) {
                    applyValue(buf, index, valueFormat, sub + 6);
                }
                else {
                    if (cov >= u16(b, sub + 6))
                        return -1;
                    applyValue(buf, index, valueFormat, sub + 8 + cov * valueSize(valueFormat));
                }
                return index + 1;

            case 2: // Pair adjustment
                var format = u16(b, sub);
                var cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (cov < 0)
                    return -1;
                var second = nextIndex(buf, index, flag, markSet);
                if (second < 0)
                    return -1;
                var gid2 = buf.glyphs[second];
                var vf1 = u16(b, sub + 4);
                var vf2 = u16(b, sub + 6);
                var size1 = valueSize(vf1);
                var size2 = valueSize(vf2);
                if (format == 1) {
                    if (cov >= u16(b, sub + 8))
                        return -1;
                    var set = sub + u16(b, sub + 10 + cov * 2);
                    var count = u16(b, set);
                    var recordSize = 2 + size1 + size2;
                    var lo = 0;
                    var hi = count - 1;
                    while (lo <= hi) {
                        var mid = (lo + hi) >> 1;
                        var rec = set + 2 + mid * recordSize;
                        var g = u16(b, rec);
                        if (g < gid2) lo = mid + 1;
                        else if (g > gid2) hi = mid - 1;
                        else {
                            applyValue(buf, index, vf1, rec + 2);
                            applyValue(buf, second, vf2, rec + 2 + size1);
                            return size2 > 0 ? second + 1 : second;
                        }
                    }
                    return -1;
                }
                else if (format == 2) {
                    var classDef1 = sub + u16(b, sub + 8);
                    var classDef2 = sub + u16(b, sub + 10);
                    var class1Count = u16(b, sub + 12);
                    var class2Count = u16(b, sub + 14);
                    var c1 = OtCommon.classOf(b, classDef1, gid);
                    var c2 = OtCommon.classOf(b, classDef2, gid2);
                    if (c1 >= class1Count || c2 >= class2Count)
                        return -1;
                    var rec = sub + 16 + (c1 * class2Count + c2) * (size1 + size2);
                    applyValue(buf, index, vf1, rec);
                    applyValue(buf, second, vf2, rec + size1);
                    return size2 > 0 ? second + 1 : second;
                }
                return -1;

            case 4: // Mark to base
                if (buf.classes[index] != Gdef.MARK)
                    return -1;
                var markCov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (markCov < 0)
                    return -1;
                // Find the base: previous glyph that is not a mark
                var j = index - 1;
                while (j >= 0 && buf.classes[j] == Gdef.MARK)
                    j--;
                if (j < 0)
                    return -1;
                var baseCov = OtCommon.coverageIndex(b, sub + u16(b, sub + 4), buf.glyphs[j]);
                if (baseCov < 0)
                    return -1;
                var classCount = u16(b, sub + 6);
                var markArray = sub + u16(b, sub + 8);
                var baseArray = sub + u16(b, sub + 10);
                return attach(buf, index, j, markCov, baseCov, classCount, markArray, baseArray);

            case 6: // Mark to mark
                if (buf.classes[index] != Gdef.MARK)
                    return -1;
                var mark1Cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 2), gid);
                if (mark1Cov < 0)
                    return -1;
                var j = prevIndex(buf, index, flag, markSet);
                if (j < 0 || buf.classes[j] != Gdef.MARK)
                    return -1;
                var mark2Cov = OtCommon.coverageIndex(b, sub + u16(b, sub + 4), buf.glyphs[j]);
                if (mark2Cov < 0)
                    return -1;
                var classCount = u16(b, sub + 6);
                var mark1Array = sub + u16(b, sub + 8);
                var mark2Array = sub + u16(b, sub + 10);
                return attach(buf, index, j, mark1Cov, mark2Cov, classCount, mark1Array, mark2Array);

            case 7:
                return applyContext(buf, index, sub, false, flag, markSet);

            case 8:
                return applyContext(buf, index, sub, true, flag, markSet);

            default:
                return -1;
        }

    }

    function attach(buf:GlyphBuffer, index:Int, target:Int, markCov:Int, targetCov:Int, classCount:Int, markArray:Int, targetArray:Int):Int {
        var b = data;
        if (markCov >= u16(b, markArray) || targetCov >= u16(b, targetArray))
            return -1;
        var markRecord = markArray + 2 + markCov * 4;
        var markClass = u16(b, markRecord);
        if (markClass >= classCount)
            return -1;
        var markAnchorOffset = u16(b, markRecord + 2);
        var targetAnchorOffset = u16(b, targetArray + 2 + (targetCov * classCount + markClass) * 2);
        if (markAnchorOffset == 0 || targetAnchorOffset == 0)
            return -1;
        var markAnchor = markArray + markAnchorOffset;
        var targetAnchor = targetArray + targetAnchorOffset;
        buf.xOffset[index] = s16(b, targetAnchor + 2) - s16(b, markAnchor + 2);
        buf.yOffset[index] = s16(b, targetAnchor + 4) - s16(b, markAnchor + 4);
        buf.attachTo[index] = target;
        return index + 1;
    }

}
