// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.

import haxe.Json;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import ttf.Font;
import ttf.GlyphBox;
import ttf.GlyphRasterizer;
import ttf.OutlineSink;
import ttf.Utf8;
import ttf.atlas.GlyphAtlas;
import ttf.shape.FontRun;
import ttf.shape.Features;
import ttf.shape.Shaper;

/**
 * Test runner: compares the library with reference data produced by
 * fontTools, HarfBuzz and FreeType (see reference-gen/), plus unit tests.
 *
 * Run from the test/ directory. Pass `--verbose` to list every mismatch.
 */
class Main {

    static var failures = 0;
    static var checks = 0;
    static var verbose = false;
    static var fonts:Map<String, Bytes> = new Map();

    static function main() {

        #if js
        var args:Array<String> = js.Syntax.code('process.argv.slice(2)');
        #else
        var args = Sys.args();
        #end
        verbose = args.indexOf('--verbose') >= 0;

        var reference:Dynamic = Json.parse(Fs.getText('reference/reference.json'));
        println('Reference tools: HarfBuzz ' + reference.tools.harfbuzz + ', FreeType ' + reference.tools.freetype);

        var entries:Array<Dynamic> = reference.fonts;
        for (entry in entries) {
            var file:String = entry.file;
            var index:Int = entry.index;
            var font = Font.fromBytes(fontBytes(file), index);
            println('');
            println('== $file #$index (${font.familyName} ${font.styleName}, ${font.isCff ? "CFF" : "glyf"})');
            checkMetrics(font, entry.metrics);
            checkCmap(font, entry.cmap);
            checkGlyphs(font, entry.glyphs);
            if (entry.shaping != null)
                checkShaping(font, entry.shaping);
            if (entry.raster != null)
                checkRaster(font, entry.raster);
        }

        println('');
        println('== Unit tests');
        testUtf8();
        testFallback();
        testFallbackSpaces();
        testFeatures();
        testSinglePrecision();
        testAtlas();
        testCollection();

        println('');
        println('== Benchmarks');
        benchmark();

        println('');
        println('$checks checks, $failures failures');
        #if js
        js.Syntax.code('process.exitCode = {0}', failures > 0 ? 1 : 0);
        #else
        Sys.exit(failures > 0 ? 1 : 0);
        #end
    }

    static function println(line:String):Void {
        #if js
        js.Syntax.code('console.log({0})', line);
        #else
        Sys.println(line);
        #end
    }

    static function fontBytes(file:String):Bytes {
        var bytes = fonts.get(file);
        if (bytes == null) {
            bytes = Fs.getBytes('fonts/' + file);
            fonts.set(file, bytes);
        }
        return bytes;
    }

    static function check(ok:Bool, message:String):Bool {
        checks++;
        if (!ok) {
            failures++;
            println('  FAIL ' + message);
        }
        return ok;
    }

    static function report(name:String, total:Int, bad:Int, ?extra:String):Void {
        checks++;
        if (bad > 0)
            failures++;
        println('  ' + (bad == 0 ? 'ok  ' : 'FAIL') + ' $name: ${total - bad}/$total match' + (extra != null ? ' ($extra)' : ''));
    }

/// Metrics, cmap, glyphs

    static function checkMetrics(font:Font, m:Dynamic):Void {
        var fm = font.metrics;
        var bad = 0;
        inline function eq(name:String, a:Float, b:Float) {
            if (Math.abs(a - b) > 1e-6) {
                bad++;
                println('    metrics.$name: $a, expected $b');
            }
        }
        eq('unitsPerEm', font.unitsPerEm, m.unitsPerEm);
        eq('numGlyphs', font.numGlyphs, m.numGlyphs);
        eq('ascent', fm.ascent, m.ascent);
        eq('descent', fm.descent, m.descent);
        eq('lineGap', fm.lineGap, m.lineGap);
        eq('underlinePosition', fm.underlinePosition, m.underlinePosition);
        if (m.underlineThickness != 0)
            eq('underlineThickness', fm.underlineThickness, m.underlineThickness);
        if (m.capHeight != 0)
            eq('capHeight', fm.capHeight, m.capHeight);
        if (m.xHeight != 0)
            eq('xHeight', fm.xHeight, m.xHeight);
        eq('xMin', fm.xMin, m.bbox[0]);
        eq('yMin', fm.yMin, m.bbox[1]);
        eq('xMax', fm.xMax, m.bbox[2]);
        eq('yMax', fm.yMax, m.bbox[3]);
        if (font.familyName != m.family) {
            bad++;
            println('    family: ${font.familyName}, expected ${m.family}');
        }
        if (font.styleName != m.style) {
            bad++;
            println('    style: ${font.styleName}, expected ${m.style}');
        }
        report('metrics and names', 16, bad);
    }

    static function checkCmap(font:Font, cmap:Array<Array<Int>>):Void {
        var bad = 0;
        for (pair in cmap) {
            var gid = font.glyphForChar(pair[0]);
            if (gid != pair[1]) {
                bad++;
                if (verbose) println('    cmap U+${StringTools.hex(pair[0], 4)}: $gid, expected ${pair[1]}');
            }
        }
        report('cmap', cmap.length, bad);
    }

    static function checkGlyphs(font:Font, glyphs:Array<Array<Float>>):Void {
        var badMetrics = 0;
        var badBox = 0;
        var badArea = 0;
        var box = new GlyphBox();
        var area = new AreaSink();
        var maxAreaError = 0.0;
        for (g in glyphs) {
            var gid = Std.int(g[0]);
            if (font.advance(gid) != g[1] || font.leftSideBearing(gid) != g[2]) {
                badMetrics++;
                if (verbose) println('    glyph $gid advance/lsb: ${font.advance(gid)} ${font.leftSideBearing(gid)}, expected ${g[1]} ${g[2]}');
            }
            font.glyphBox(gid, box);
            if (Math.abs(box.xMin - g[3]) > 0.01 || Math.abs(box.yMin - g[4]) > 0.01
                || Math.abs(box.xMax - g[5]) > 0.01 || Math.abs(box.yMax - g[6]) > 0.01) {
                badBox++;
                if (verbose) println('    glyph $gid box: $box, expected ${g.slice(3, 7)}');
            }
            area.reset();
            font.outline(gid, area);
            var expected = g[7];
            var error = Math.abs(area.value - expected) / Math.max(1, Math.abs(expected));
            if (error > maxAreaError) maxAreaError = error;
            if (error > 1e-5) {
                badArea++;
                if (verbose) println('    glyph $gid area: ${area.value}, expected $expected');
            }
        }
        report('advances and side bearings', glyphs.length, badMetrics);
        report('outline control boxes', glyphs.length, badBox);
        report('outline areas', glyphs.length, badArea, 'max relative error ' + fmt(maxAreaError, 9));
    }

/// Shaping

    static function checkShaping(font:Font, cases:Array<Dynamic>):Void {
        var shaper = new Shaper();
        var bad = 0;
        for (c in cases) {
            var text:String = c.text;
            var expected:Array<Array<Int>> = c.glyphs;
            var line = shaper.layoutLine(text, font.unitsPerEm, [new FontRun(Utf8.byteLength(text), font)]);
            var glyphs = [];
            for (run in line.runs)
                for (g in run.glyphs)
                    glyphs.push(g);
            var ok = glyphs.length == expected.length && Math.abs(line.width - (c.width:Float)) < 1e-6;
            if (ok) {
                for (i in 0...glyphs.length) {
                    var g = glyphs[i];
                    var e = expected[i];
                    if (g.id != e[0] || g.index != e[1] || Math.abs(g.x - e[2]) > 1e-6 || Math.abs(g.y + e[3]) > 1e-6) {
                        ok = false;
                        break;
                    }
                }
            }
            if (!ok) {
                bad++;
                println('    shaping mismatch for "' + text + '"');
                println('      got:      ' + [for (g in glyphs) '${g.id}@${g.index}:${g.x},${-g.y}'].join(' ') + ' width ${line.width}');
                println('      expected: ' + [for (e in expected) '${e[0]}@${e[1]}:${e[2]},${e[3]}'].join(' ') + ' width ${c.width}');
            }
        }
        report('shaping vs HarfBuzz (glyphs, clusters, positions)', cases.length, bad);

        // Units exposed per glyph: pen (sum of advances) plus offsets gives the position
        var badUnits = 0;
        // Single precision mode: the same glyphs, positions within f32 rounding
        var single = new Shaper();
        single.singlePrecision = true;
        var badSingle = 0;
        var size = 16.0;
        for (c in cases) {
            var text:String = c.text;
            var expected:Array<Array<Int>> = c.glyphs;
            var len = Utf8.byteLength(text);
            var line = shaper.layoutLine(text, font.unitsPerEm, [new FontRun(len, font)]);
            var pen = 0;
            var ok = true;
            for (run in line.runs) {
                for (g in run.glyphs) {
                    if (g.x != pen + g.xOffsetUnits || -g.y != g.yOffsetUnits)
                        ok = false;
                    pen += g.advanceUnits;
                }
            }
            if (!ok || pen != line.width)
                badUnits++;
            var f = single.layoutLine(text, size, [new FontRun(len, font)]);
            var glyphs = [for (run in f.runs) for (g in run.glyphs) g];
            var scale = size / font.unitsPerEm;
            ok = glyphs.length == expected.length;
            if (ok) {
                for (i in 0...glyphs.length) {
                    var g = glyphs[i];
                    var e = expected[i];
                    var ex = e[2] * scale;
                    // Each f32 operation rounds by at most half an ulp (6e-8 relative)
                    var tolerance = 1.2e-7 * (i + 2) * Math.max(Math.abs(ex), size);
                    if (g.id != e[0] || g.index != e[1] || Math.abs(g.x - ex) > tolerance || Math.abs(g.y + e[3] * scale) > 1e-5 || g.x != Shaper.f32(g.x)) {
                        ok = false;
                        break;
                    }
                }
            }
            if (!ok || Math.abs(f.width - (c.width:Float) * scale) > 1.2e-7 * (glyphs.length + 2) * Math.max(f.width, size)) {
                badSingle++;
                if (verbose) println('    single precision mismatch for "' + text + '"');
            }
        }
        report('glyph advances and offsets in font units', cases.length, badUnits);
        report('single precision shaping vs HarfBuzz', cases.length, badSingle);
    }

/// Rasterization

    static function checkRaster(font:Font, cases:Array<Dynamic>):Void {
        var rasterizer = new GlyphRasterizer();
        var badBounds = 0;
        var maxDiff = 0;
        var sumDiff = 0.0;
        var pixels = 0;
        var bigDiffs = 0;
        var badQuality = 0;
        for (c in cases) {
            var gid:Int = c.gid;
            var size:Float = c.size;
            var subx:Float = c.subx;
            var bitmap = rasterizer.rasterize(font, gid, size, subx, 0);
            var refData = Base64.decode(c.data);
            var refLeft:Int = c.left;
            var refTop:Int = c.top;
            var refWidth:Int = c.width;
            var refHeight:Int = c.height;
            if (bitmap.left != refLeft || bitmap.top != refTop || bitmap.width != refWidth || bitmap.height != refHeight) {
                badBounds++;
                if (verbose) println('    raster gid $gid size $size subx $subx bounds: ${bitmap.left},${bitmap.top} ${bitmap.width}x${bitmap.height}, expected $refLeft,$refTop ${refWidth}x$refHeight');
            }
            // Compare on the union of both frames
            var x0 = Std.int(Math.min(bitmap.left, refLeft));
            var x1 = Std.int(Math.max(bitmap.left + bitmap.width, refLeft + refWidth));
            var y0 = Std.int(Math.min(-bitmap.top, -refTop));
            var y1 = Std.int(Math.max(-bitmap.top + bitmap.height, -refTop + refHeight));
            var caseMax = 0;
            for (y in y0...y1) {
                for (x in x0...x1) {
                    var a = 0;
                    var bx = x - bitmap.left;
                    var by = y + bitmap.top;
                    if (bx >= 0 && by >= 0 && bx < bitmap.width && by < bitmap.height)
                        a = bitmap.data.get(by * bitmap.width + bx);
                    var b = 0;
                    var rx = x - refLeft;
                    var ry = y + refTop;
                    if (rx >= 0 && ry >= 0 && rx < refWidth && ry < refHeight)
                        b = refData.get(ry * refWidth + rx);
                    var d = a > b ? a - b : b - a;
                    if (d > caseMax) caseMax = d;
                    if (d > 16) bigDiffs++;
                    sumDiff += d;
                    pixels++;
                }
            }
            if (caseMax > maxDiff) maxDiff = caseMax;
            if (caseMax > 8) {
                badQuality++;
                if (verbose) println('    raster gid $gid size $size subx $subx: max diff $caseMax');
            }
        }
        report('raster bounds vs FreeType', cases.length, badBounds);
        report('raster coverage vs FreeType (max diff <= 8)', cases.length, badQuality,
            'max diff $maxDiff, mean diff ${fmt(sumDiff / Math.max(1, pixels), 3)}, ${bigDiffs} of $pixels pixels differ by more than 16');
    }

/// Unit tests

    static function testUtf8():Void {
        var s = 'aé€\u{1F600}b';
        check(Utf8.byteLength(s) == 1 + 2 + 3 + 4 + 1, 'Utf8.byteLength');
        var cps = [];
        var offsets = [];
        var n = Utf8.decode(s, cps, offsets);
        check(n == 5, 'Utf8.decode count');
        check(cps[3] == 0x1F600 && offsets[3] == 6 && offsets[4] == 10, 'Utf8.decode values');
        check(Utf8.byteOffsetToIndex(s, 6) == 3 && Utf8.byteOffsetToIndex(s, 10) == 5, 'Utf8.byteOffsetToIndex');
        check(Utf8.indexToByteOffset(s, 5) == 10 && Utf8.indexToByteOffset(s, 2) == 3, 'Utf8.indexToByteOffset');
        println('  ok   utf8 helpers');
    }

    static function testFallback():Void {
        var inter = Font.fromBytes(fontBytes('Inter-Regular.ttf'));
        var mono = Font.fromBytes(fontBytes('JetBrainsMono-Regular.ttf'));
        var shaper = new Shaper();
        // U+2208 (element of) and U+211D (double struck R) are not in Inter
        var text = 'x ∈ ℝ, y';
        var line = shaper.layoutLine(text, 16, [new FontRun(Utf8.byteLength(text), inter, [mono])]);
        var fonts = [for (run in line.runs) run.font == inter ? 'I' : 'M'];
        var ok = check(fonts.join('') == 'IMIMI', 'fallback runs: ' + fonts.join(''));
        // Glyph indices are UTF-8 offsets
        var indices = [for (run in line.runs) for (g in run.glyphs) g.index];
        ok = check(indices.join(',') == '0,1,2,5,6,9,10,11', 'fallback indices: ' + indices.join(',')) && ok;
        // Each fallback glyph is the font's own glyph
        ok = check(line.runs[1].glyphs[0].id == mono.glyphForChar(0x2208), 'fallback glyph id') && ok;
        ok = check(line.ascent > 0 && line.descent > 0 && line.len == Utf8.byteLength(text), 'line metrics') && ok;
        if (ok) println('  ok   font fallback (GPUI rules)');
    }

    /**
     * HarfBuzz normalization fallbacks (also done by rustybuzz, checked
     * against GPUI's cosmic-text text system): a Unicode space the font
     * lacks is drawn with the space glyph and a fallback advance, a missing
     * U+2011 with the U+2010 hyphen, and the primary font is kept.
     */
    static function testFallbackSpaces():Void {
        var inter = Font.fromBytes(fontBytes('Inter-Regular.ttf'));
        var mono = Font.fromBytes(fontBytes('JetBrainsMono-Regular.ttf'));
        var shaper = new Shaper();
        var ok = check(mono.glyphForChar(0x202F) == 0 && mono.glyphForChar(0x2011) == 0, 'JetBrains Mono lacks U+202F and U+2011');
        // Narrow no-break space: half of the space advance, in the primary font
        var text = 'a\u202Fb';
        var line = shaper.layoutLine(text, 1000, [new FontRun(Utf8.byteLength(text), mono, [inter])]);
        ok = check(line.runs.length == 1 && line.runs[0].font == mono, 'fallback space stays in the primary font') && ok;
        var glyphs = line.runs[0].glyphs;
        ok = check(glyphs[1].id == mono.glyphForChar(0x20) && glyphs[2].x - glyphs[1].x == 300, 'narrow space: space glyph, half advance') && ok;
        // Em, en and thin spaces, figure space
        text = 'a\u2003b\u2002c\u2009d\u2007e';
        line = shaper.layoutLine(text, 1000, [new FontRun(Utf8.byteLength(text), mono)]);
        glyphs = line.runs[0].glyphs;
        ok = check(glyphs[2].x - glyphs[1].x == 1000 && glyphs[4].x - glyphs[3].x == 500 && glyphs[6].x - glyphs[5].x == 200 && glyphs[8].x - glyphs[7].x == 600, 'em, en, thin and figure spaces') && ok;
        // Non-breaking hyphen
        text = 'a\u2011b';
        line = shaper.layoutLine(text, 1000, [new FontRun(Utf8.byteLength(text), mono, [inter])]);
        ok = check(line.runs.length == 1 && line.runs[0].glyphs[1].id == mono.glyphForChar(0x2010), 'U+2011 drawn with U+2010') && ok;
        if (ok) println('  ok   fallback spaces and hyphen (HarfBuzz rules)');
    }

    static function testFeatures():Void {
        var font = Font.fromBytes(fontBytes('KernLigaTest.ttf'));
        var shaper = new Shaper();
        var text = 'fi';
        var line = shaper.layoutLine(text, 1000, [new FontRun(2, font)]);
        var ok = check(line.glyphCount() == 1 && line.runs[0].glyphs[0].id == 9, 'liga enabled');
        var noLiga = Features.DEFAULT.with('liga', false);
        line = shaper.layoutLine(text, 1000, [new FontRun(2, font, null, noLiga)]);
        ok = check(line.glyphCount() == 2, 'liga disabled') && ok;
        var noKern = Features.DEFAULT.with('kern', false);
        line = shaper.layoutLine('AV', 1000, [new FontRun(2, font, null, noKern)]);
        ok = check(line.runs[0].glyphs[1].x == 600, 'kern disabled') && ok;
        // Ligature and kerning across two runs of the same font do not interact
        line = shaper.layoutLine('fifi', 1000, [new FontRun(1, font), new FontRun(3, font)]);
        ok = check(line.glyphCount() == 3, 'runs are shaped separately') && ok;
        ok = check(shaper.pairKerning(font, font.glyphForChar('A'.code), font.glyphForChar('V'.code)) == -80, 'pair kerning (kern table)') && ok;
        var inter = Font.fromBytes(fontBytes('Inter-Regular.ttf'));
        var a = inter.glyphForChar('A'.code);
        var v = inter.glyphForChar('V'.code);
        line = shaper.layoutLine('AV', inter.unitsPerEm, [new FontRun(2, inter)]);
        var expected = line.runs[0].glyphs[1].x - inter.advance(a);
        ok = check(expected != 0 && shaper.pairKerning(inter, a, v) == expected, 'pair kerning (GPOS)') && ok;
        if (ok) println('  ok   feature toggles and pair kerning');
    }

    /**
     * Single precision mode against cosmic-text 0.19, as used by GPUI's text
     * system: "macro" in JetBrains Mono at 14 px is 5 advances of 600/1000 em,
     * each `f32(14 * f32(0.6))`, summed in f32 (GPUI measures 42.0000038).
     */
    static function testSinglePrecision():Void {
        var mono = Font.fromBytes(fontBytes('JetBrainsMono-Regular.ttf'));
        var shaper = new Shaper();
        var line = shaper.layoutLine('macro', 14, [new FontRun(5, mono)]);
        var ok = check(line.width == 42, 'double precision width: ${line.width}');
        shaper.singlePrecision = true;
        line = shaper.layoutLine('macro', 14, [new FontRun(5, mono)]);
        ok = check(line.width == 42.000003814697266, 'single precision width: ${line.width}') && ok;
        var xs = [for (g in line.runs[0].glyphs) g.x];
        var expectedXs = [0, 8.40000057220459, 16.80000114440918, 25.200000762939453, 33.60000228881836];
        ok = check(xs.length == 5 && [for (i in 0...5) xs[i] == expectedXs[i]].indexOf(false) == -1, 'single precision positions: ${xs.join(",")}') && ok;
        ok = check(line.ascent == Shaper.f32(14 * Shaper.f32(mono.metrics.ascent / mono.unitsPerEm)), 'single precision ascent') && ok;
        if (ok) println('  ok   single precision (cosmic-text f32 arithmetic)');
    }

    static function testAtlas():Void {
        var atlas = new GlyphAtlas(64, 64, 2, 1);
        var evicted = 0;
        atlas.onPageEvicted = page -> evicted++;
        var ok = true;
        for (i in 0...40) {
            atlas.frame = i;
            var region = atlas.allocate(14, 14);
            ok = ok && region != null;
        }
        ok = check(ok && atlas.pages.length == 2, 'atlas pages: ${atlas.pages.length}');
        ok = check(evicted >= 1, 'atlas eviction: $evicted') && ok;
        var region = atlas.allocate(10, 10);
        var src = Bytes.alloc(100);
        src.fill(0, 100, 200);
        atlas.write(region, src, 0, 10);
        var page = region.page;
        ok = check(page.isDirty() && page.data.get(region.y * 64 + region.x) == 200, 'atlas write') && ok;
        ok = check(atlas.allocate(80, 10) == null, 'atlas rejects oversized images') && ok;
        if (ok) println('  ok   glyph atlas (allocation, eviction, writes)');
    }

    static function testCollection():Void {
        var bytes = fontBytes('Collection-subset.ttc');
        var ok = check(Font.faceCount(bytes) == 2, 'collection face count');
        var a = Font.fromBytes(bytes, 0);
        var b = Font.fromBytes(bytes, 1);
        ok = check(a.familyName == 'Inter' && b.familyName == 'JetBrains Mono', 'collection faces') && ok;
        if (ok) println('  ok   collections');
    }

/// Benchmarks

    static function benchmark():Void {
        var font = Font.fromBytes(fontBytes('Inter-Regular.ttf'));
        var otf = Font.fromBytes(fontBytes('Inter-Regular.otf'));
        var rasterizer = new GlyphRasterizer();
        var text = 'The quick brown fox jumps over the lazy dog. AVATAR Tokyo WAVE 0123456789';
        var gids = [for (i in 0...text.length) font.glyphForChar(text.charCodeAt(i))];
        var otfGids = [for (i in 0...text.length) otf.glyphForChar(text.charCodeAt(i))];

        var bitmap = new ttf.GlyphRasterizer.GlyphBitmap();
        var t0 = Fs.stamp();
        var count = 0;
        for (round in 0...20) {
            for (g in gids) {
                rasterizer.rasterize(font, g, 16 + (round & 3), (round & 3) * 0.25, 0, bitmap);
                count++;
            }
        }
        var t1 = Fs.stamp();
        println('  rasterize glyf 16-19px: ${fmt((t1 - t0) * 1e6 / count, 1)} us/glyph');

        t0 = Fs.stamp();
        count = 0;
        for (round in 0...20) {
            for (g in otfGids) {
                rasterizer.rasterize(otf, g, 16 + (round & 3), (round & 3) * 0.25, 0, bitmap);
                count++;
            }
        }
        t1 = Fs.stamp();
        println('  rasterize CFF 16-19px: ${fmt((t1 - t0) * 1e6 / count, 1)} us/glyph');

        var shaper = new Shaper();
        var runs = [new FontRun(Utf8.byteLength(text), font)];
        t0 = Fs.stamp();
        for (i in 0...500)
            shaper.layoutLine(text, 16, runs);
        t1 = Fs.stamp();
        println('  shape ${text.length} chars (GSUB + GPOS): ${fmt((t1 - t0) * 1e6 / 500, 1)} us/line');
    }

    static function fmt(v:Float, digits:Int):String {
        var p = Math.pow(10, digits);
        return Std.string(Math.round(v * p) / p);
    }

}

/**
 * Signed area of an outline (positive for counter-clockwise contours),
 * computed exactly with a 3 point Gauss-Legendre quadrature of -y dx.
 * Same convention as fontTools' AreaPen.
 */
class AreaSink implements OutlineSink {

    public var value:Float = 0;

    var x0:Float = 0;
    var y0:Float = 0;
    var startX:Float = 0;
    var startY:Float = 0;

    static final T = [0.5 - Math.sqrt(0.15), 0.5, 0.5 + Math.sqrt(0.15)];
    static final W = [5 / 18, 8 / 18, 5 / 18];

    public function new() {}

    public function reset():Void {
        value = 0;
    }

    public function moveTo(x:Float, y:Float):Void {
        x0 = startX = x;
        y0 = startY = y;
    }

    public function lineTo(x:Float, y:Float):Void {
        value -= (x - x0) * (y + y0) * 0.5;
        x0 = x;
        y0 = y;
    }

    public function quadTo(cx:Float, cy:Float, x:Float, y:Float):Void {
        cubicTo(x0 + (cx - x0) * 2 / 3, y0 + (cy - y0) * 2 / 3, x + (cx - x) * 2 / 3, y + (cy - y) * 2 / 3, x, y);
    }

    public function cubicTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, x:Float, y:Float):Void {
        var sum = 0.0;
        for (k in 0...3) {
            var t = T[k];
            var mt = 1 - t;
            var py = mt * mt * mt * y0 + 3 * mt * mt * t * c1y + 3 * mt * t * t * c2y + t * t * t * y;
            var dx = 3 * mt * mt * (c1x - x0) + 6 * mt * t * (c2x - c1x) + 3 * t * t * (x - c2x);
            sum += W[k] * py * dx;
        }
        value -= sum;
        x0 = x;
        y0 = y;
    }

    public function close():Void {
        if (x0 != startX || y0 != startY)
            lineTo(startX, startY);
    }

}
