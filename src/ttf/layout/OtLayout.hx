// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Shared part of `GSUB` and `GPOS`: script and feature selection, lookup
 * access, lookup flags (glyph skipping) and contextual lookups (formats 1,
 * 2 and 3 of context and chained context subtables), which are identical
 * in both tables.
 */
class OtLayout {

    // Lookup flags
    static inline var IGNORE_BASE_GLYPHS = 0x0002;
    static inline var IGNORE_LIGATURES = 0x0004;
    static inline var IGNORE_MARKS = 0x0008;
    static inline var USE_MARK_FILTERING_SET = 0x0010;
    static inline var MARK_ATTACHMENT_TYPE = 0xFF00;

    // Sequence matching kinds
    static inline var MATCH_GLYPH = 0;
    static inline var MATCH_CLASS = 1;
    static inline var MATCH_COVERAGE = 2;

    static inline var MAX_NESTING = 8;

    var data:Bytes;

    var gdef:Gdef;

    var scriptList:Int = -1;

    var featureList:Int = -1;

    var lookupList:Int = -1;

    public var lookupCount(default, null):Int = 0;

    var lookupsCache:Map<String, Array<Int>> = new Map();

    var lookupsByKey:Map<Int, Array<Int>> = new Map();

    /** Positions of the matched input glyphs of the last context match. */
    var matchPositions:Array<Array<Int>> = [for (i in 0...MAX_NESTING + 1) []];

    var nesting:Int = 0;

    /** Per lookup set of glyphs that can start a match (null entry: not computed). */
    var digests:Array<Bytes> = [];

    var numGlyphs:Int = 0;

    public function new(data:Bytes, offset:Int, gdef:Gdef, numGlyphs:Int) {
        this.data = data;
        this.gdef = gdef;
        this.numGlyphs = numGlyphs;
        if (offset < 0)
            return;
        scriptList = offset + u16(data, offset + 4);
        featureList = offset + u16(data, offset + 6);
        lookupList = offset + u16(data, offset + 8);
        lookupCount = u16(data, lookupList);
    }

    /**
     * Returns true if the given feature is available for the given script
     * (default language system).
     */
    public function hasFeature(script:String, feature:String):Bool {
        return lookupsFor(script, [feature]).length > 0;
    }

    /**
     * Same as `lookupsFor()`, cached with an integer key chosen by the
     * caller (no allocation once cached).
     */
    public function lookupsForKey(key:Int, script:String, features:Array<String>):Array<Int> {
        var result = lookupsByKey.get(key);
        if (result == null) {
            result = lookupsFor(script, features);
            lookupsByKey.set(key, result);
        }
        return result;
    }

    /**
     * Sorted list of lookup indices to apply for the given script and
     * features (default language system, plus the required feature).
     */
    public function lookupsFor(script:String, features:Array<String>):Array<Int> {

        var key = script + ':' + features.join(',');
        var cached = lookupsCache.get(key);
        if (cached != null)
            return cached;

        var result:Array<Int> = [];
        if (scriptList >= 0) {
            var b = data;
            var langSys = findLangSys(script);
            if (langSys < 0) langSys = findLangSys('DFLT');
            if (langSys < 0) langSys = findLangSys('dflt');
            if (langSys < 0) langSys = findLangSys('latn');
            if (langSys >= 0) {
                var wanted = [for (f in features) Bin.tagToInt(f)];
                var required = u16(b, langSys + 2);
                var count = u16(b, langSys + 4);
                var featureCount = u16(b, featureList);
                for (k in -1...count) {
                    var fi = k < 0 ? required : u16(b, langSys + 6 + k * 2);
                    if (fi == 0xFFFF || fi >= featureCount)
                        continue;
                    var rec = featureList + 2 + fi * 6;
                    var tag = u32(b, rec);
                    if (k >= 0 && wanted.indexOf(tag) < 0)
                        continue;
                    var feature = featureList + u16(b, rec + 4);
                    var n = u16(b, feature + 2);
                    for (j in 0...n) {
                        var li = u16(b, feature + 4 + j * 2);
                        if (li < lookupCount && result.indexOf(li) < 0)
                            result.push(li);
                    }
                }
            }
        }
        result.sort((a, b) -> a - b);
        lookupsCache.set(key, result);
        return result;

    }

    function findLangSys(script:String):Int {
        var b = data;
        var tag = Bin.tagToInt(script);
        var count = u16(b, scriptList);
        for (i in 0...count) {
            var rec = scriptList + 2 + i * 6;
            if (u32(b, rec) == tag) {
                var s = scriptList + u16(b, rec + 4);
                var defaultLangSys = u16(b, s);
                if (defaultLangSys != 0)
                    return s + defaultLangSys;
                // No default language system: use the first one
                if (u16(b, s + 2) > 0)
                    return s + u16(b, s + 6);
                return -1;
            }
        }
        return -1;
    }

    /**
     * Returns a byte per glyph telling whether a glyph can start a match of
     * the lookup (union of the first coverage of its subtables). Lets the
     * apply loops skip most glyphs without reading subtables.
     */
    function digest(lookupIndex:Int):Bytes {
        var d = digests[lookupIndex];
        if (d != null)
            return d;
        d = Bytes.alloc(numGlyphs + 1);
        var lookup = lookupOffset(lookupIndex);
        var type = lookupType(lookup);
        var count = subtableCount(lookup);
        var all = false;
        for (s in 0...count) {
            var sub = subtableOffset(lookup, s);
            var t = type;
            if (t == extensionType()) {
                t = u16(data, sub + 2);
                sub = sub + u32(data, sub + 4);
            }
            var cov = firstCoverage(t, sub);
            if (cov < 0) {
                all = true;
                break;
            }
            addCoverage(d, cov);
        }
        if (all)
            d.fill(0, numGlyphs + 1, 1);
        digests[lookupIndex] = d;
        return d;
    }

    function addCoverage(d:Bytes, cov:Int):Void {
        var b = data;
        var format = u16(b, cov);
        var n = numGlyphs;
        if (format == 1) {
            var count = u16(b, cov + 2);
            for (i in 0...count) {
                var g = u16(b, cov + 4 + i * 2);
                if (g < n) d.set(g, 1);
            }
        }
        else if (format == 2) {
            var count = u16(b, cov + 2);
            for (i in 0...count) {
                var r = cov + 4 + i * 6;
                var start = u16(b, r);
                var end = u16(b, r + 2);
                if (end >= n) end = n - 1;
                for (g in start...end + 1)
                    d.set(g, 1);
            }
        }
    }

    /** Lookup type of extension subtables (7 in GSUB, 9 in GPOS). */
    function extensionType():Int {
        return -1;
    }

    /**
     * Absolute offset of the coverage table of the first glyph matched by
     * a subtable, or -1 if unknown.
     */
    function firstCoverage(type:Int, sub:Int):Int {
        return -1;
    }

    /** First coverage of context (`chained` false) or chained context subtables. */
    function contextFirstCoverage(sub:Int, chained:Bool):Int {
        var b = data;
        var format = u16(b, sub);
        if (format == 1 || format == 2)
            return sub + u16(b, sub + 2);
        if (format == 3) {
            if (chained) {
                var backtrackCount = u16(b, sub + 2);
                var inputPos = sub + 4 + backtrackCount * 2;
                if (u16(b, inputPos) == 0)
                    return -1;
                return sub + u16(b, inputPos + 2);
            }
            if (u16(b, sub + 2) == 0)
                return -1;
            return sub + u16(b, sub + 6);
        }
        return -1;
    }

    inline function lookupOffset(index:Int):Int {
        return lookupList + u16(data, lookupList + 2 + index * 2);
    }

    inline function lookupType(lookup:Int):Int {
        return u16(data, lookup);
    }

    inline function lookupFlag(lookup:Int):Int {
        return u16(data, lookup + 2);
    }

    inline function subtableCount(lookup:Int):Int {
        return u16(data, lookup + 4);
    }

    inline function subtableOffset(lookup:Int, index:Int):Int {
        return lookup + u16(data, lookup + 6 + index * 2);
    }

    inline function markFilteringSet(lookup:Int):Int {
        var flag = lookupFlag(lookup);
        if ((flag & USE_MARK_FILTERING_SET) != 0)
            return u16(data, lookup + 6 + subtableCount(lookup) * 2);
        return -1;
    }

    /**
     * Returns true if the glyph at `index` must be skipped by a lookup
     * with the given flag and mark filtering set.
     */
    function skip(buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Bool {
        var glyphClass = buf.classes[index];
        if (glyphClass == Gdef.HIDDEN)
            return true;
        if ((flag & 0xFF1E) == 0)
            return false;
        if (glyphClass == Gdef.BASE)
            return (flag & IGNORE_BASE_GLYPHS) != 0;
        if (glyphClass == Gdef.LIGATURE)
            return (flag & IGNORE_LIGATURES) != 0;
        if (glyphClass == Gdef.MARK) {
            if ((flag & IGNORE_MARKS) != 0)
                return true;
            if ((flag & USE_MARK_FILTERING_SET) != 0)
                return gdef == null || !gdef.inMarkSet(markSet, buf.glyphs[index]);
            var attachType = (flag & MARK_ATTACHMENT_TYPE) >> 8;
            if (attachType != 0)
                return gdef == null || gdef.markAttachClass(buf.glyphs[index]) != attachType;
        }
        return false;
    }

    function nextIndex(buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {
        var i = index + 1;
        while (i < buf.length) {
            if (!skip(buf, i, flag, markSet))
                return i;
            i++;
        }
        return -1;
    }

    function prevIndex(buf:GlyphBuffer, index:Int, flag:Int, markSet:Int):Int {
        var i = index - 1;
        while (i >= 0) {
            if (!skip(buf, i, flag, markSet))
                return i;
            i--;
        }
        return -1;
    }

    inline function matchValue(kind:Int, value:Int, base:Int, classDef:Int, gid:Int):Bool {
        return switch kind {
            case MATCH_GLYPH: gid == value;
            case MATCH_CLASS: OtCommon.classOf(data, classDef, gid) == value;
            default: OtCommon.coverageIndex(data, base + value, gid) >= 0;
        }
    }

    /**
     * Applies a lookup once at the given position (used by contextual
     * lookups). Returns true if something was applied.
     */
    function applyNested(lookupIndex:Int, buf:GlyphBuffer, index:Int):Bool {
        return false;
    }

    /**
     * Context (format 1, 2, 3) and chained context (format 1, 2, 3)
     * subtables. Returns the index after the matched input sequence, or
     * -1 when nothing matched.
     */
    function applyContext(buf:GlyphBuffer, index:Int, sub:Int, chained:Bool, flag:Int, markSet:Int):Int {

        if (nesting >= MAX_NESTING)
            return -1;

        var b = data;
        var format = u16(b, sub);
        var gid = buf.glyphs[index];

        if (format == 1 || format == 2) {
            var coverage = sub + u16(b, sub + 2);
            var covIndex = OtCommon.coverageIndex(b, coverage, gid);
            if (covIndex < 0)
                return -1;

            var backtrackClassDef = -1;
            var inputClassDef = -1;
            var lookaheadClassDef = -1;
            var setIndex = covIndex;
            var setCountPos:Int;
            var kind = MATCH_GLYPH;

            if (format == 1) {
                setCountPos = sub + 4;
            }
            else {
                kind = MATCH_CLASS;
                if (chained) {
                    var o = u16(b, sub + 4);
                    backtrackClassDef = o != 0 ? sub + o : -1;
                    o = u16(b, sub + 6);
                    inputClassDef = o != 0 ? sub + o : -1;
                    o = u16(b, sub + 8);
                    lookaheadClassDef = o != 0 ? sub + o : -1;
                    setCountPos = sub + 10;
                }
                else {
                    var o = u16(b, sub + 4);
                    inputClassDef = o != 0 ? sub + o : -1;
                    backtrackClassDef = lookaheadClassDef = inputClassDef;
                    setCountPos = sub + 6;
                }
                setIndex = OtCommon.classOf(b, inputClassDef, gid);
            }

            var setCount = u16(b, setCountPos);
            if (setIndex >= setCount)
                return -1;
            var setOffset = u16(b, setCountPos + 2 + setIndex * 2);
            if (setOffset == 0)
                return -1;
            var ruleSet = sub + setOffset;
            var ruleCount = u16(b, ruleSet);
            for (r in 0...ruleCount) {
                var rule = ruleSet + u16(b, ruleSet + 2 + r * 2);
                var result:Int;
                if (chained) {
                    var backtrackCount = u16(b, rule);
                    var backtrack = rule + 2;
                    var inputPos = backtrack + backtrackCount * 2;
                    var inputCount = u16(b, inputPos);
                    var input = inputPos + 2;
                    var lookaheadPos = input + (inputCount > 0 ? inputCount - 1 : 0) * 2;
                    var lookaheadCount = u16(b, lookaheadPos);
                    var lookahead = lookaheadPos + 2;
                    var recordsPos = lookahead + lookaheadCount * 2;
                    var recordCount = u16(b, recordsPos);
                    result = matchAndApply(buf, index, flag, markSet, sub,
                        kind, backtrackClassDef, backtrack, backtrackCount,
                        kind, inputClassDef, input, inputCount, true,
                        kind, lookaheadClassDef, lookahead, lookaheadCount,
                        recordsPos + 2, recordCount);
                }
                else {
                    var inputCount = u16(b, rule);
                    var recordCount = u16(b, rule + 2);
                    var input = rule + 4;
                    var records = input + (inputCount > 0 ? inputCount - 1 : 0) * 2;
                    result = matchAndApply(buf, index, flag, markSet, sub,
                        kind, -1, 0, 0,
                        kind, inputClassDef, input, inputCount, true,
                        kind, -1, 0, 0,
                        records, recordCount);
                }
                if (result >= 0)
                    return result;
            }
            return -1;
        }

        if (format == 3) {
            if (chained) {
                var backtrackCount = u16(b, sub + 2);
                var backtrack = sub + 4;
                var inputPos = backtrack + backtrackCount * 2;
                var inputCount = u16(b, inputPos);
                var input = inputPos + 2;
                var lookaheadPos = input + inputCount * 2;
                var lookaheadCount = u16(b, lookaheadPos);
                var lookahead = lookaheadPos + 2;
                var recordsPos = lookahead + lookaheadCount * 2;
                var recordCount = u16(b, recordsPos);
                if (inputCount == 0 || OtCommon.coverageIndex(b, sub + u16(b, input), gid) < 0)
                    return -1;
                return matchAndApply(buf, index, flag, markSet, sub,
                    MATCH_COVERAGE, -1, backtrack, backtrackCount,
                    MATCH_COVERAGE, -1, input, inputCount, false,
                    MATCH_COVERAGE, -1, lookahead, lookaheadCount,
                    recordsPos + 2, recordCount);
            }
            else {
                var inputCount = u16(b, sub + 2);
                var recordCount = u16(b, sub + 4);
                var input = sub + 6;
                if (inputCount == 0 || OtCommon.coverageIndex(b, sub + u16(b, input), gid) < 0)
                    return -1;
                return matchAndApply(buf, index, flag, markSet, sub,
                    MATCH_COVERAGE, -1, 0, 0,
                    MATCH_COVERAGE, -1, input, inputCount, false,
                    MATCH_COVERAGE, -1, 0, 0,
                    input + inputCount * 2, recordCount);
            }
        }

        return -1;

    }

    /**
     * Matches backtrack, input and lookahead sequences around `index`, then
     * applies the nested lookup records. `inputSkipsFirst` is true when the
     * input array does not contain the first glyph (formats 1 and 2).
     */
    function matchAndApply(buf:GlyphBuffer, index:Int, flag:Int, markSet:Int, base:Int,
        backtrackKind:Int, backtrackClassDef:Int, backtrack:Int, backtrackCount:Int,
        inputKind:Int, inputClassDef:Int, input:Int, inputCount:Int, inputSkipsFirst:Bool,
        lookaheadKind:Int, lookaheadClassDef:Int, lookahead:Int, lookaheadCount:Int,
        records:Int, recordCount:Int):Int {

        var b = data;
        if (inputCount == 0)
            return -1;

        var positions = matchPositions[nesting];
        positions[0] = index;

        // Input sequence
        var pos = index;
        for (k in 1...inputCount) {
            pos = nextIndex(buf, pos, flag, markSet);
            if (pos < 0)
                return -1;
            var value = u16(b, input + (inputSkipsFirst ? k - 1 : k) * 2);
            if (!matchValue(inputKind, value, base, inputClassDef, buf.glyphs[pos]))
                return -1;
            positions[k] = pos;
        }
        var lastInput = pos;

        // Backtrack (stored closest first)
        pos = index;
        for (k in 0...backtrackCount) {
            pos = prevIndex(buf, pos, flag, markSet);
            if (pos < 0)
                return -1;
            if (!matchValue(backtrackKind, u16(b, backtrack + k * 2), base, backtrackClassDef, buf.glyphs[pos]))
                return -1;
        }

        // Lookahead
        pos = lastInput;
        for (k in 0...lookaheadCount) {
            pos = nextIndex(buf, pos, flag, markSet);
            if (pos < 0)
                return -1;
            if (!matchValue(lookaheadKind, u16(b, lookahead + k * 2), base, lookaheadClassDef, buf.glyphs[pos]))
                return -1;
        }

        // Apply nested lookups
        var end = lastInput + 1;
        nesting++;
        for (r in 0...recordCount) {
            var seqIndex = u16(b, records + r * 4);
            var lookupIndex = u16(b, records + r * 4 + 2);
            if (seqIndex >= inputCount)
                continue;
            var at = positions[seqIndex];
            if (at >= buf.length)
                continue;
            var before = buf.length;
            applyNested(lookupIndex, buf, at);
            var delta = buf.length - before;
            if (delta != 0) {
                end += delta;
                for (k in seqIndex + 1...inputCount) {
                    positions[k] += delta;
                }
            }
        }
        nesting--;

        if (end <= index)
            end = index + 1;
        return end;

    }

}
