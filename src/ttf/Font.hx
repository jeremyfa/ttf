// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;
import ttf.Bin.*;
import ttf.layout.Gdef;
import ttf.layout.Gpos;
import ttf.layout.Gsub;
import ttf.layout.KernTable;

/**
 * A font face loaded from TrueType (`.ttf`), OpenType CFF / CFF2 (`.otf`)
 * or collection (`.ttc` / `.otc`) data.
 *
 * Tables are read directly from the font bytes when needed: loading a
 * font only parses the table directory, the metrics and the names.
 *
 * ```haxe
 * var font = Font.fromBytes(bytes);
 * var gid = font.glyphForChar('A'.code);
 * var advance = font.advance(gid) * fontSize / font.unitsPerEm;
 * ```
 */
class Font {

    /** The whole font file (shared by every face of a collection). */
    public var data(default, null):Bytes;

    /** Index of this face in its collection (0 for single fonts). */
    public var faceIndex(default, null):Int;

    public var numGlyphs(default, null):Int = 0;

    public var unitsPerEm(default, null):Int = 1000;

    public var metrics(default, null):FontMetrics;

    /** Family name (typographic family when available). */
    public var familyName(default, null):String = '';

    /** Style name (typographic subfamily when available), like `Regular` or `Bold Italic`. */
    public var styleName(default, null):String = '';

    public var fullName(default, null):String = '';

    public var postScriptName(default, null):String = '';

    /** `OS/2` weight class (400 regular, 700 bold), 400 when unknown. */
    public var weight(default, null):Int = 400;

    public var italic(default, null):Bool = false;

    /** True for CFF / CFF2 (cubic) outlines, false for TrueType (quadratic) outlines. */
    public var isCff(default, null):Bool = false;

    /** True when the font has a monospace flag (`post.isFixedPitch`). */
    public var isMonospace(default, null):Bool = false;

    public var cmap(default, null):Cmap;

    public var gdef(default, null):Gdef = null;

    public var gsub(default, null):Gsub = null;

    public var gpos(default, null):Gpos = null;

    public var kern(default, null):KernTable = null;

    /**
     * Apple's `morx` table when the font has one and no `GSUB` (HarfBuzz
     * shapes such fonts with `morx`), else null.
     */
    public var morx(default, null):ttf.layout.Morx = null;

    var directory:Int;

    var tableTags:Array<Int> = [];

    var tableOffsets:Array<Int> = [];

    var tableLengths:Array<Int> = [];

    var numberOfHMetrics:Int = 0;

    var hmtx:Int = -1;

    var glyf:GlyfOutline = null;

    var cff:CffOutline = null;

    var boundsSink:BoundsSink = new BoundsSink();

    /** Cached control boxes (4 values per glyph), computed on demand. */
    var boxes:haxe.ds.Vector<Float> = null;

    var boxesReady:Bytes = null;

    /** Source of the tables left out of `data` (see `fromSource()`), or null. */
    var source:Null<FontSource> = null;

    var externalTags:Array<Int> = [];

    var externalOffsets:Array<Int> = [];

    var externalLengths:Array<Int> = [];

    var colorGlyphs:Null<ttf.color.ColorGlyphs> = null;

    /**
     * Tables that `fromSource()` leaves in the source by default: color and
     * monochrome bitmap data, read glyph by glyph.
     */
    public static final LARGE_TABLES:Array<String> = ['sbix', 'CBDT', 'EBDT', 'SVG ', 'bdat'];

    /**
     * Number of faces in the given font data: the number of fonts for a
     * collection, 1 for a single font, 0 if the data is not a font.
     */
    public static function faceCount(data:Bytes):Int {
        if (data == null || data.length < 12)
            return 0;
        var tag = u32(data, 0);
        if (tag == 0x74746366) // 'ttcf'
            return u32(data, 8);
        if (tag == 0x00010000 || tag == 0x4F54544F || tag == 0x74727565) // 1.0, 'OTTO', 'true'
            return 1;
        return 0;
    }

    /**
     * Loads the face at `faceIndex` (0 for single fonts). Throws if the data
     * is not a supported font.
     */
    public static function fromBytes(data:Bytes, faceIndex:Int = 0):Font {
        return new Font(data, faceIndex);
    }

    /**
     * Loads the face at `faceIndex` from a `FontSource`, reading only the
     * table directory and the tables of that face, except the large tables
     * (`LARGE_TABLES` by default), which stay in the source and are read
     * piece by piece when glyphs are rendered (`readTable()`). `data` then
     * holds a single font made of the loaded tables, not the file.
     *
     * Throws if the data is not a supported font.
     */
    public static function fromSource(source:FontSource, faceIndex:Int = 0, ?largeTables:Array<String>):Font {
        if (largeTables == null)
            largeTables = LARGE_TABLES;
        var header = source.read(0, 12);
        var count = header != null ? faceCount(header) : 0;
        if (count == 0)
            throw 'Font: unsupported font data';
        if (faceIndex < 0 || faceIndex >= count)
            throw 'Font: invalid face index $faceIndex (the font has $count faces)';
        var directory = 0;
        if (u32(header, 0) == 0x74746366) {
            var entry = source.read(12 + faceIndex * 4, 4);
            if (entry == null || entry.length < 4)
                throw 'Font: truncated collection header';
            directory = u32(entry, 0);
        }
        var dirHeader = source.read(directory, 12);
        if (dirHeader == null || dirHeader.length < 12)
            throw 'Font: truncated table directory';
        var numTables = u16(dirHeader, 4);
        var records = source.read(directory + 12, numTables * 16);
        if (records == null || records.length < numTables * 16)
            throw 'Font: truncated table directory';

        var largeTags = [for (tag in largeTables) Bin.tagToInt(tag)];
        var tags:Array<Int> = [];
        var offsets:Array<Int> = [];
        var lengths:Array<Int> = [];
        var extTags:Array<Int> = [];
        var extOffsets:Array<Int> = [];
        var extLengths:Array<Int> = [];
        for (i in 0...numTables) {
            var tag = u32(records, i * 16);
            var offset = u32(records, i * 16 + 8);
            var length = u32(records, i * 16 + 12);
            if (offset < 0 || length < 0 || offset + length > source.length)
                continue;
            if (largeTags.indexOf(tag) != -1) {
                extTags.push(tag);
                extOffsets.push(offset);
                extLengths.push(length);
            }
            else {
                tags.push(tag);
                offsets.push(offset);
                lengths.push(length);
            }
        }

        // A single font made of the loaded tables, each one 4-byte aligned
        var n = tags.length;
        var size = 12 + n * 16;
        var newOffsets:Array<Int> = [];
        for (i in 0...n) {
            newOffsets.push(size);
            size += (lengths[i] + 3) & ~3;
        }
        var data = Bytes.alloc(size);
        data.fill(0, size, 0);
        inline function w16(o:Int, v:Int) {
            data.set(o, (v >> 8) & 0xFF);
            data.set(o + 1, v & 0xFF);
        }
        inline function w32(o:Int, v:Int) {
            w16(o, (v >> 16) & 0xFFFF);
            w16(o + 2, v & 0xFFFF);
        }
        w32(0, u32(dirHeader, 0));
        w16(4, n);
        for (i in 0...n) {
            var rec = 12 + i * 16;
            w32(rec, tags[i]);
            w32(rec + 8, newOffsets[i]);
            w32(rec + 12, lengths[i]);
        }

        // Read the tables, merging the ones that are close in the file
        var order = [for (i in 0...n) i];
        order.sort((a, b) -> offsets[a] - offsets[b]);
        var k = 0;
        while (k < n) {
            var start = offsets[order[k]];
            var end = start + lengths[order[k]];
            var last = k;
            while (last + 1 < n) {
                var next = order[last + 1];
                if (offsets[next] > end + 65536)
                    break;
                var nextEnd = offsets[next] + lengths[next];
                if (nextEnd > end)
                    end = nextEnd;
                last++;
            }
            var chunk = source.read(start, end - start);
            if (chunk == null || chunk.length < end - start)
                throw 'Font: cannot read the tables';
            for (j in k...last + 1) {
                var t = order[j];
                data.blit(newOffsets[t], chunk, offsets[t] - start, lengths[t]);
            }
            k = last + 1;
        }

        var font = new Font(data, 0);
        font.source = source;
        font.externalTags = extTags;
        font.externalOffsets = extOffsets;
        font.externalLengths = extLengths;
        font.faceIndex = faceIndex;
        return font;
    }

    public function new(data:Bytes, faceIndex:Int = 0) {

        this.data = data;
        this.faceIndex = faceIndex;

        var count = faceCount(data);
        if (count == 0)
            throw 'Font: unsupported font data';
        if (faceIndex < 0 || faceIndex >= count)
            throw 'Font: invalid face index $faceIndex (the font has $count faces)';

        directory = 0;
        if (u32(data, 0) == 0x74746366)
            directory = u32(data, 12 + faceIndex * 4);

        var numTables = u16(data, directory + 4);
        for (i in 0...numTables) {
            var rec = directory + 12 + i * 16;
            tableTags.push(u32(data, rec));
            tableOffsets.push(u32(data, rec + 8));
            tableLengths.push(u32(data, rec + 12));
        }

        var head = table('head');
        if (head < 0)
            throw 'Font: missing head table';
        unitsPerEm = u16(data, head + 18);
        if (unitsPerEm <= 0)
            unitsPerEm = 1000;
        var indexToLocFormat = s16(data, head + 50);

        var maxp = table('maxp');
        numGlyphs = maxp >= 0 ? u16(data, maxp + 4) : 0;

        var hhea = table('hhea');
        if (hhea >= 0)
            numberOfHMetrics = u16(data, hhea + 34);
        hmtx = table('hmtx');
        if (hmtx >= 0 && numberOfHMetrics * 4 > tableLength('hmtx'))
            numberOfHMetrics = Std.int(tableLength('hmtx') / 4);

        cmap = new Cmap(data, table('cmap'), tableLength('cmap'));

        var glyfOffset = table('glyf');
        var locaOffset = table('loca');
        var cffOffset = table('CFF ');
        var cff2Offset = table('CFF2');
        if (glyfOffset >= 0 && locaOffset >= 0) {
            glyf = new GlyfOutline(data, glyfOffset, tableLength('glyf'), locaOffset, indexToLocFormat == 1, numGlyphs);
        }
        else if (cffOffset >= 0) {
            isCff = true;
            cff = new CffOutline(data, cffOffset, tableLength('CFF '), false, numGlyphs);
        }
        else if (cff2Offset >= 0) {
            isCff = true;
            cff = new CffOutline(data, cff2Offset, tableLength('CFF2'), true, numGlyphs);
        }

        var gdefOffset = table('GDEF');
        if (gdefOffset >= 0)
            gdef = new Gdef(data, gdefOffset);
        var gsubOffset = table('GSUB');
        if (gsubOffset >= 0)
            gsub = new Gsub(data, gsubOffset, gdef, numGlyphs);
        var gposOffset = table('GPOS');
        if (gposOffset >= 0)
            gpos = new Gpos(data, gposOffset, gdef, numGlyphs);
        var morxOffset = table('morx');
        if (morxOffset >= 0 && gsub == null) {
            morx = new ttf.layout.Morx(data, morxOffset, tableLength('morx'));
            if (morx.isEmpty) morx = null;
        }
        var kernOffset = table('kern');
        if (kernOffset >= 0) {
            kern = new KernTable(data, kernOffset, tableLength('kern'));
            if (kern.isEmpty) kern = null;
        }

        readNames();
        readMetrics(head, hhea);

    }

    /**
     * Absolute offset of a table in `data`, or -1 if the font has no such table.
     */
    public function table(tag:String):Int {
        var t = Bin.tagToInt(tag);
        for (i in 0...tableTags.length) {
            if (tableTags[i] == t)
                return tableOffsets[i];
        }
        return -1;
    }

    public function tableLength(tag:String):Int {
        var t = Bin.tagToInt(tag);
        for (i in 0...tableTags.length) {
            if (tableTags[i] == t)
                return tableLengths[i];
        }
        for (i in 0...externalTags.length) {
            if (externalTags[i] == t)
                return externalLengths[i];
        }
        return 0;
    }

    /**
     * True if the font has the table, loaded in `data` or left in its
     * source (see `fromSource()`).
     */
    public function hasTable(tag:String):Bool {
        if (table(tag) >= 0)
            return true;
        var t = Bin.tagToInt(tag);
        return externalTags.indexOf(t) != -1;
    }

    /**
     * Gives access to `length` bytes at `offset` in a table, whether it is
     * in `data` or left in the source: `out.bytes` holds them from
     * `out.pos`. Returns false if the range is outside the table.
     */
    public function readTable(tag:String, offset:Int, length:Int, out:TableRange):Bool {
        if (offset < 0 || length < 0)
            return false;
        var t = Bin.tagToInt(tag);
        for (i in 0...tableTags.length) {
            if (tableTags[i] == t) {
                if (offset + length > tableLengths[i])
                    return false;
                out.bytes = data;
                out.pos = tableOffsets[i] + offset;
                return true;
            }
        }
        if (source != null) {
            for (i in 0...externalTags.length) {
                if (externalTags[i] == t) {
                    if (offset + length > externalLengths[i])
                        return false;
                    var bytes = source.read(externalOffsets[i] + offset, length);
                    if (bytes == null || bytes.length < length)
                        return false;
                    out.bytes = bytes;
                    out.pos = 0;
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * True if the font has color glyph tables (`COLR` / `CPAL`, `sbix`,
     * `CBDT` / `CBLC`).
     */
    public var hasColorGlyphs(get, never):Bool;

    var colorState:Int = 0;

    function get_hasColorGlyphs():Bool {
        if (colorState == 0)
            colorState = ttf.color.ColorGlyphs.hasColorTables(this) ? 1 : 2;
        return colorState == 1;
    }

    /**
     * Color glyph data of the font (`COLR` / `CPAL`, `sbix`, `CBDT` /
     * `CBLC`), or null if it has none.
     */
    public function color():Null<ttf.color.ColorGlyphs> {
        if (colorGlyphs == null) {
            if (!hasColorGlyphs)
                return null;
            colorGlyphs = new ttf.color.ColorGlyphs(this);
        }
        return colorGlyphs;
    }

    function readMetrics(head:Int, hhea:Int):Void {

        var m = new FontMetrics();
        m.unitsPerEm = unitsPerEm;
        m.xMin = s16(data, head + 36);
        m.yMin = s16(data, head + 38);
        m.xMax = s16(data, head + 40);
        m.yMax = s16(data, head + 42);
        var macStyle = u16(data, head + 44);
        italic = (macStyle & 2) != 0;

        var hheaAscender = 0;
        var hheaDescender = 0;
        var hheaLineGap = 0;
        if (hhea >= 0) {
            hheaAscender = s16(data, hhea + 4);
            hheaDescender = s16(data, hhea + 6);
            hheaLineGap = s16(data, hhea + 8);
        }

        var os2 = table('OS/2');
        var useTypo = false;
        var typoAscender = 0;
        var typoDescender = 0;
        var typoLineGap = 0;
        var winAscent = 0;
        var winDescent = 0;
        var os2Version = -1;
        if (os2 >= 0) {
            os2Version = u16(data, os2);
            weight = u16(data, os2 + 4);
            var fsSelection = u16(data, os2 + 62);
            useTypo = (fsSelection & 0x80) != 0;
            if ((fsSelection & 1) != 0) italic = true;
            if (tableLength('OS/2') >= 78) {
                typoAscender = s16(data, os2 + 68);
                typoDescender = s16(data, os2 + 70);
                typoLineGap = s16(data, os2 + 72);
                winAscent = u16(data, os2 + 74);
                winDescent = u16(data, os2 + 76);
            }
            if (os2Version >= 2 && tableLength('OS/2') >= 90) {
                m.xHeight = s16(data, os2 + 86);
                m.capHeight = s16(data, os2 + 88);
            }
        }

        if (useTypo && (typoAscender != 0 || typoDescender != 0)) {
            m.ascent = typoAscender;
            m.descent = typoDescender;
            m.lineGap = typoLineGap;
        }
        else if (hheaAscender != 0 || hheaDescender != 0) {
            m.ascent = hheaAscender;
            m.descent = hheaDescender;
            m.lineGap = hheaLineGap;
        }
        else if (typoAscender != 0 || typoDescender != 0) {
            m.ascent = typoAscender;
            m.descent = typoDescender;
            m.lineGap = typoLineGap;
        }
        else {
            m.ascent = winAscent;
            m.descent = -winDescent;
            m.lineGap = 0;
        }

        var post = table('post');
        if (post >= 0) {
            m.underlinePosition = s16(data, post + 8);
            m.underlineThickness = s16(data, post + 10);
            isMonospace = u32(data, post + 12) != 0;
        }
        if (m.underlineThickness == 0)
            m.underlineThickness = Math.round(unitsPerEm / 14);

        metrics = m;

        // Measure glyphs when OS/2 does not provide x height / cap height
        if (m.xHeight == 0) {
            var box = glyphBox(glyphForChar('x'.code), new GlyphBox());
            m.xHeight = box.yMax;
        }
        if (m.capHeight == 0) {
            var box = glyphBox(glyphForChar('H'.code), new GlyphBox());
            m.capHeight = box.yMax;
        }

    }

    function readNames():Void {
        var name = table('name');
        if (name < 0)
            return;
        var count = u16(data, name + 2);
        var stringOffset = name + u16(data, name + 4);
        var best:Array<Int> = [for (i in 0...18) -1];
        var values:Array<String> = [for (i in 0...18) null];
        for (i in 0...count) {
            var rec = name + 6 + i * 12;
            var platformId = u16(data, rec);
            var encodingId = u16(data, rec + 2);
            var languageId = u16(data, rec + 4);
            var nameId = u16(data, rec + 6);
            if (nameId > 17)
                continue;
            var length = u16(data, rec + 8);
            var offset = stringOffset + u16(data, rec + 10);
            var score = -1;
            if (platformId == 3 && (encodingId == 1 || encodingId == 10)) score = languageId == 0x409 ? 4 : 3;
            else if (platformId == 0) score = 2;
            else if (platformId == 1 && encodingId == 0) score = languageId == 0 ? 1 : 0;
            if (score <= best[nameId] || offset + length > data.length)
                continue;
            best[nameId] = score;
            values[nameId] = platformId == 1 ? decodeLatin1(offset, length) : decodeUtf16Be(offset, length);
        }
        if (values[16] != null) {
            familyName = values[16];
            styleName = values[17] != null ? values[17] : (values[2] != null ? values[2] : '');
        }
        else {
            familyName = values[1] != null ? values[1] : '';
            styleName = values[2] != null ? values[2] : '';
        }
        fullName = values[4] != null ? values[4] : '';
        postScriptName = values[6] != null ? values[6] : '';
    }

    function decodeUtf16Be(offset:Int, length:Int):String {
        var buf = new StringBuf();
        var i = 0;
        while (i + 1 < length) {
            var c = u16(data, offset + i);
            i += 2;
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < length) {
                var c2 = u16(data, offset + i);
                if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                    i += 2;
                    c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                }
            }
            buf.addChar(c);
        }
        return buf.toString();
    }

    function decodeLatin1(offset:Int, length:Int):String {
        var buf = new StringBuf();
        for (i in 0...length)
            buf.addChar(data.get(offset + i));
        return buf.toString();
    }

/// Characters and metrics

    /**
     * Glyph id of a code point, or 0 (`.notdef`) if the font does not map it.
     */
    public inline function glyphForChar(codePoint:Int):Int {
        return cmap.glyphId(codePoint);
    }

    /**
     * Glyph id of a variation sequence (code point + variation selector).
     */
    public function glyphForCharVariant(codePoint:Int, selector:Int):Int {
        var g = cmap.variantGlyphId(codePoint, selector);
        return g >= 0 ? g : cmap.glyphId(codePoint);
    }

    /** True if the font maps the code point to a glyph. */
    public inline function hasChar(codePoint:Int):Bool {
        return cmap.glyphId(codePoint) != 0;
    }

    /**
     * Horizontal advance of a glyph, in font units.
     */
    public function advance(gid:Int):Int {
        if (hmtx < 0 || numberOfHMetrics == 0)
            return 0;
        if (gid < numberOfHMetrics)
            return u16(data, hmtx + gid * 4);
        return u16(data, hmtx + (numberOfHMetrics - 1) * 4);
    }

    /**
     * Left side bearing of a glyph, in font units.
     */
    public function leftSideBearing(gid:Int):Int {
        if (hmtx < 0 || numberOfHMetrics == 0)
            return 0;
        if (gid < numberOfHMetrics)
            return s16(data, hmtx + gid * 4 + 2);
        var p = hmtx + numberOfHMetrics * 4 + (gid - numberOfHMetrics) * 2;
        return p + 1 < data.length ? s16(data, p) : 0;
    }

    /** Scale factor from font units to pixels for the given font size. */
    public inline function scaleForSize(fontSize:Float):Float {
        return fontSize / unitsPerEm;
    }

/// Outlines

    /**
     * Emits the outline of a glyph (font units, y up) into `sink`.
     * Returns false if the glyph has no outline (like a space).
     */
    public function outline(gid:Int, sink:OutlineSink):Bool {
        if (glyf != null)
            return glyf.decompose(gid, sink);
        if (cff != null)
            return cff.decompose(gid, sink);
        return false;
    }

    /**
     * Emits the outline of a glyph scaled to `ppem` pixels per em (pixels,
     * y up). TrueType outlines are scaled to 26.6 fixed point exactly like
     * FreeType (see `GlyfOutline.decomposeScaled()`), CFF outlines in
     * floating point. Returns false if the glyph has no outline.
     */
    public function outlineScaled(gid:Int, ppem:Float, sink:OutlineSink):Bool {
        if (glyf != null)
            return glyf.decomposeScaled(gid, ppem, unitsPerEm, sink);
        if (cff != null) {
            var scaled = new ScaledOutlineSink(sink, ppem / unitsPerEm);
            return cff.decompose(gid, scaled);
        }
        return false;
    }

    /**
     * Control box of a glyph outline in font units (every point, control
     * points included). Empty glyphs get a zero box. Results are cached.
     */
    public function glyphBox(gid:Int, out:GlyphBox):GlyphBox {
        if (gid < 0 || gid >= numGlyphs)
            return out.set(0, 0, 0, 0);
        if (boxes == null) {
            boxes = new haxe.ds.Vector(numGlyphs * 4);
            boxesReady = Bytes.alloc(numGlyphs);
            boxesReady.fill(0, numGlyphs, 0);
        }
        var k = gid * 4;
        if (boxesReady.get(gid) == 0) {
            var sink = boundsSink;
            sink.reset();
            outline(gid, sink);
            if (sink.empty) {
                boxes[k] = 0;
                boxes[k + 1] = 0;
                boxes[k + 2] = 0;
                boxes[k + 3] = 0;
            }
            else {
                boxes[k] = sink.xMin;
                boxes[k + 1] = sink.yMin;
                boxes[k + 2] = sink.xMax;
                boxes[k + 3] = sink.yMax;
            }
            boxesReady.set(gid, 1);
        }
        return out.set(boxes[k], boxes[k + 1], boxes[k + 2], boxes[k + 3]);
    }

    /**
     * Typographic bounds of a glyph, in font units: the glyph box, like
     * CoreText's bounding rects used by GPUI on macOS.
     */
    public inline function typographicBounds(gid:Int, out:GlyphBox):GlyphBox {
        return glyphBox(gid, out);
    }

    public function toString():String {
        return 'Font($familyName $styleName)';
    }

}

/** Scales font units to pixels (floating point). */
private class ScaledOutlineSink implements OutlineSink {

    var target:OutlineSink;

    var scale:Float;

    public function new(target:OutlineSink, scale:Float) {
        this.target = target;
        this.scale = scale;
    }

    public function moveTo(x:Float, y:Float):Void {
        target.moveTo(x * scale, y * scale);
    }

    public function lineTo(x:Float, y:Float):Void {
        target.lineTo(x * scale, y * scale);
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        target.quadTo(cx * scale, cy * scale, x * scale, y * scale);
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        target.cubicTo(c1x * scale, c1y * scale, c2x * scale, c2y * scale, x * scale, y * scale);
    }

    public function close():Void {
        target.close();
    }

}
