// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.

import haxe.Json;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import ttf.Font;
import ttf.FontSource;
import ttf.color.ColorBitmap;
import ttf.color.Inflate;
import ttf.color.Png;

/**
 * Color glyphs (`sbix`, `CBDT` / `CBLC`, `COLR` / `CPAL`), checked against
 * swash 0.2.10 (reference/color.json, see reference-gen/swash-color), plus
 * what swash does not do: 16-bit PNG images (swash panics on them), Apple's
 * `flip` glyphs, and partial loading through `Font.fromSource()`.
 */
@:access(Main)
class ColorTests {

    /** Largest difference allowed per channel (swash resamples in f32, ttf in f64) */
    static inline final TOLERANCE = 2;

    public static function run():Void {
        testInflate();
        var reference:Dynamic = Json.parse(Fs.getText('reference/color.json'));
        var entries:Array<Dynamic> = reference.fonts;
        for (entry in entries) {
            var file:String = entry.file;
            var system = file.charAt(0) == '/';
            if (system && !Fs.exists(file)) {
                Main.println('  skip $file (not on this system)');
                continue;
            }
            var font = system ? fileFont(file, entry.index) : Font.fromBytes(Main.fontBytes(file), entry.index);
            checkColorGlyphs(file + (system ? ' (partial reads)' : ''), font, entry.glyphs);
            if (!system) {
                // The same font with its bitmap tables left in the source
                var partial = Font.fromSource(new BytesFontSource(Main.fontBytes(file)), entry.index);
                checkColorGlyphs(file + ' (fromSource)', partial, entry.glyphs);
            }
        }
        testSixteenBitPng();
        testFlip();
        testAstralCmap();
        testFromSource();
        testColorFallback();
        testPrimaryKeepsCoveredEmoji();
        testMorx();
    }

    /** `morx` ligatures of Apple Color Emoji against HarfBuzz (reference/morx.json) */
    static function testMorx():Void {
        var reference:Dynamic = Json.parse(Fs.getText('reference/morx.json'));
        // Clusters of emoji sequences, with a font without emoji
        var inter = Font.fromBytes(Main.fontBytes(reference.clusterFont));
        var clusterCases:Array<Dynamic> = reference.clusterCases;
        var bad = 0;
        var shaper = new ttf.shape.Shaper();
        for (c in clusterCases) {
            var text:String = c.text;
            var line = shaper.layoutLine(text, 16, [new ttf.shape.FontRun(ttf.Utf8.byteLength(text), inter)]);
            var glyphs = [for (run in line.runs) for (g in run.glyphs) g.id];
            var clusters = [for (run in line.runs) for (g in run.glyphs) g.index];
            if (glyphs.toString() != (c.glyphs:Array<Int>).toString() || clusters.toString() != (c.clusters:Array<Int>).toString()) {
                bad++;
                Main.println('    $text: glyphs $glyphs clusters $clusters, expected ${c.glyphs} ${c.clusters}');
            }
        }
        Main.report('emoji sequence clusters (${reference.tool})', clusterCases.length, bad);
        var path:String = reference.font;
        if (!Fs.exists(path)) {
            Main.println('  skip morx ($path not on this system)');
            return;
        }
        var font = fileFont(path, 0);
        if (!Main.check(font.morx != null, 'Apple Color Emoji has a morx table'))
            return;
        var cases:Array<Dynamic> = reference.cases;
        bad = 0;
        for (c in cases) {
            var text:String = c.text;
            var line = shaper.layoutLine(text, 16, [new ttf.shape.FontRun(ttf.Utf8.byteLength(text), font)]);
            var glyphs = [for (run in line.runs) for (g in run.glyphs) g.id];
            var clusters = [for (run in line.runs) for (g in run.glyphs) g.index];
            var expectedGlyphs:Array<Int> = c.glyphs;
            var expectedClusters:Array<Int> = c.clusters;
            if (glyphs.toString() != expectedGlyphs.toString() || clusters.toString() != expectedClusters.toString()) {
                bad++;
                Main.println('    $text: glyphs $glyphs clusters $clusters, expected $expectedGlyphs $expectedClusters');
            }
        }
        Main.report('morx (Apple Color Emoji, ${reference.tool})', cases.length, bad);
    }

    /** `primaryKeepsCoveredEmoji`: cosmic-text's rule, a cluster the primary font maps stays on it */
    static function testPrimaryKeepsCoveredEmoji():Void {
        var inter = Font.fromBytes(Main.fontBytes('Inter-Regular.ttf'));
        var colr = Font.fromBytes(Main.fontBytes('ColrTest.ttf'));
        var shaper = new ttf.shape.Shaper();
        function fonts(text:String):String {
            var line = shaper.layoutLine(text, 16, [new ttf.shape.FontRun(ttf.Utf8.byteLength(text), inter, [colr])]);
            return [for (run in line.runs) run.font == inter ? 'I' : 'C'].join('');
        }
        var ok = Main.check(fonts('A\u{FE0F}') == 'C', 'default, A + VS16: ' + fonts('A\u{FE0F}'));
        shaper.primaryKeepsCoveredEmoji = true;
        // Variation selectors and joiners are ignorable: the primary keeps the cluster
        ok = Main.check(fonts('A\u{FE0F}') == 'I', 'A + VS16: ' + fonts('A\u{FE0F}')) && ok;
        ok = Main.check(fonts('x\u{E9}\u{FE0F}') == 'I', 'e acute + VS16: ' + fonts('x\u{E9}\u{FE0F}')) && ok;
        // A continuation the primary lacks (a skin tone): the color font
        ok = Main.check(fonts('x\u{E9}\u{1F3FB}') == 'IC', 'e acute + skin tone: ' + fonts('x\u{E9}\u{1F3FB}')) && ok;
        // Characters the primary lacks still prefer the color font
        ok = Main.check(fonts('x\u{1F600}') == 'IC', 'emoji: ' + fonts('x\u{1F600}')) && ok;
        Main.report('primaryKeepsCoveredEmoji', 1, ok ? 0 : 1);
    }

    /** Emoji sequences prefer the fallbacks with color glyphs */
    static function testColorFallback():Void {
        var inter = Font.fromBytes(Main.fontBytes('Inter-Regular.ttf'));
        var plain = Font.fromBytes(Main.fontBytes('KernLigaTest.ttf'));
        var colr = Font.fromBytes(Main.fontBytes('ColrTest.ttf'));
        var sbix = Font.fromBytes(Main.fontBytes('SbixTest.ttf'));
        var shaper = new ttf.shape.Shaper();
        function fonts(text:String, fallbacks:Array<Font>):String {
            var line = shaper.layoutLine(text, 16, [new ttf.shape.FontRun(ttf.Utf8.byteLength(text), inter, fallbacks)]);
            return [for (run in line.runs) run.font == inter ? 'I' : run.font == plain ? 'P' : run.font == colr ? 'C' : 'S'].join('');
        }
        var ok = Main.check(!inter.hasColorGlyphs && !plain.hasColorGlyphs && colr.hasColorGlyphs && sbix.hasColorGlyphs, 'hasColorGlyphs');
        // ASCII stays on the primary font, unless followed by variation selector 16
        ok = Main.check(fonts('A', [plain, colr]) == 'I', 'plain A: ' + fonts('A', [plain, colr])) && ok;
        ok = Main.check(fonts('A\u{FE0F}', [plain, colr]) == 'C', 'A + VS16: ' + fonts('A\u{FE0F}', [plain, colr])) && ok;
        ok = Main.check(fonts('A\u{FE0E}', [plain, colr]) == 'I', 'A + VS15: ' + fonts('A\u{FE0E}', [plain, colr])) && ok;
        // The first color font that maps the character, in fallback order
        ok = Main.check(fonts('x\u{1F600}', [colr, sbix]) == 'IC', 'emoji: ' + fonts('x\u{1F600}', [colr, sbix])) && ok;
        ok = Main.check(fonts('x\u{1F600}', [sbix, colr]) == 'IS', 'emoji order: ' + fonts('x\u{1F600}', [sbix, colr])) && ok;
        // A plain fallback that maps a character with emoji presentation loses to a color one
        shaper.isEmojiPresentation = c -> c == 0x1F600;
        ok = Main.check(fonts('x\u{1F600}', [plain, sbix]) == 'IS', 'emoji presentation: ' + fonts('x\u{1F600}', [plain, sbix])) && ok;
        // Text presentation prefers the fonts without color glyphs, wherever they are in the list
        var fromPlain = function(text:String, fallbacks:Array<Font>):String {
            var line = shaper.layoutLine(text, 16, [new ttf.shape.FontRun(ttf.Utf8.byteLength(text), plain, fallbacks)]);
            return [for (run in line.runs) run.font == inter ? 'I' : run.font == plain ? 'P' : run.font == colr ? 'C' : 'S'].join('');
        };
        ok = Main.check(fromPlain('\u{E9}', [colr, inter]) == 'I', 'text presentation: ' + fromPlain('\u{E9}', [colr, inter])) && ok;
        ok = Main.check(fromPlain('\u{E9}\u{FE0F}', [inter, colr]) == 'C', 'emoji presentation: ' + fromPlain('\u{E9}\u{FE0F}', [inter, colr])) && ok;
        ok = Main.check(fromPlain('\u{1F600}', [inter, colr]) == 'C', 'only a color font maps it: ' + fromPlain('\u{1F600}', [inter, colr])) && ok;
        shaper.isEmojiPresentation = c -> c == 0x41;
        ok = Main.check(fonts('A', [plain, colr]) == 'I', 'ASCII with emoji presentation stays plain: ' + fonts('A', [plain, colr])) && ok;
        if (ok)
            Main.println('  ok   color fonts preferred for emoji sequences');
    }

    /** Loading Apple Color Emoji with partial reads, decoding and scaling its images */
    public static function benchmark():Void {
        var path = '/System/Library/Fonts/Apple Color Emoji.ttc';
        if (!Fs.exists(path))
            return;
        var read = 0;
        var reads = 0;
        var size = Fs.fileSize(path);
        var source = new FunctionFontSource(size, (offset, length) -> {
            reads++;
            read += length;
            return Fs.readRange(path, offset, length);
        });
        var t0 = Fs.stamp();
        var font = Font.fromSource(source, 0);
        var color = font.color();
        var t1 = Fs.stamp();
        Main.println('  load Apple Color Emoji (fromSource): ${Main.fmt((t1 - t0) * 1000, 2)} ms, $read of $size bytes in $reads reads');
        var out = new ColorBitmap();
        var gids = [for (cp in [0x1F600, 0x1F602, 0x1F60D, 0x1F44D, 0x2764, 0x1F680, 0x1F389, 0x1F525]) font.glyphForChar(cp)];
        for (ppem in [16.0, 32.0, 40.0]) {
            t0 = Fs.stamp();
            var count = 0;
            for (round in 0...5) {
                for (gid in gids) {
                    color.rasterize(gid, ppem, 0, 0, out);
                    count++;
                }
            }
            t1 = Fs.stamp();
            Main.println('  rasterize Apple emoji ${ppem}px: ${Main.fmt((t1 - t0) * 1e6 / count, 1)} us/glyph (read, PNG decode${ppem == 32 || ppem == 40 ? '' : ', scale'})');
        }
    }

    static function fileFont(path:String, index:Int):Font {
        var source = new FunctionFontSource(Fs.fileSize(path), (offset, length) -> Fs.readRange(path, offset, length));
        return Font.fromSource(source, index);
    }

    static function checkColorGlyphs(name:String, font:Font, glyphs:Array<Dynamic>):Void {
        var color = font.color();
        if (!Main.check(color != null, '$name: no color tables'))
            return;
        var out = new ColorBitmap();
        var bounds = new ColorBitmap();
        var bad = 0;
        var maxDiff = 0;
        var compared = 0;
        for (g in glyphs) {
            var cp:Int = g.cp;
            var gid = font.glyphForChar(cp);
            var size:Float = g.size;
            var offset:Array<Float> = g.offset;
            if (gid != (g.gid:Int)) {
                bad++;
                Main.println('    U+${StringTools.hex(cp)}: glyph $gid, expected ${g.gid}');
                continue;
            }
            var ok = color.rasterize(gid, size, offset[0], offset[1], out);
            var hasBounds = color.bounds(gid, size, offset[0], offset[1], bounds);
            if (g.none == true) {
                // swash has no image; ttf draws `flip` glyphs (checked by testFlip)
                if (ok && !isFlip(font, gid)) {
                    bad++;
                    Main.println('    U+${StringTools.hex(cp)} @$size: unexpected image');
                }
                continue;
            }
            var expected = [(g.left:Int), (g.top:Int), (g.width:Int), (g.height:Int)];
            var got = [out.left, out.top, out.width, out.height];
            var gotBounds = [bounds.left, bounds.top, bounds.width, bounds.height];
            if (!ok || !hasBounds || got.toString() != expected.toString() || gotBounds.toString() != expected.toString()) {
                bad++;
                Main.println('    U+${StringTools.hex(cp)} @$size ${offset}: placement $got (bounds $gotBounds), expected $expected');
                continue;
            }
            if (g.rgba != null) {
                var rgba = Base64.decode(g.rgba);
                var diff = 0;
                for (i in 0...rgba.length) {
                    var d = rgba.get(i) - out.data.get(i);
                    if (d < 0) d = -d;
                    if (d > diff) diff = d;
                }
                compared++;
                if (diff > maxDiff)
                    maxDiff = diff;
                if (diff > TOLERANCE) {
                    bad++;
                    Main.println('    U+${StringTools.hex(cp)} @$size ${offset}: pixels differ by up to $diff');
                }
            }
        }
        Main.report('color glyphs $name', glyphs.length, bad, '$compared images, max channel difference $maxDiff');
    }

    static function isFlip(font:Font, gid:Int):Bool {
        var sbix = font.color() != null ? font.color().sbix : null;
        if (sbix == null)
            return false;
        // Look for a `flip` record in any strike
        var glyph = new ttf.color.BitmapGlyph();
        for (s in 0...sbix.strikeCount) {
            if (sbix.glyph(s, gid, glyph) && glyph.flip)
                return true;
        }
        return false;
    }

    static function testInflate():Void {
        // Stored, fixed and dynamic blocks, from known zlib streams
        var inflate = new Inflate();
        var stored = Bytes.ofHex('7801010500faff68656c6c6f062c0215');
        var fixed = Bytes.ofHex('78dacb48cdc9c95728cf2fca4901001a0b045d');
        var dyn = Bytes.ofHex('78da1591db11442108435bb1351fa0227241b0ff75ff9861484e884f8e94bf11051bebd8d6cec85d266eace0fe01e4dc3b22ad6e373af64d990561d6457eb2df55894917aa6299997736e17df257d07b1b1f274ef36b87a948ed2b39c39a56e92ec21a40efaabaed329ce71702258aae0e07421a0a431182cf317dba74926e68db309e5fd5992c71e5730bb1ddf9d62bf064b5b9eefc28c5659ec1c2f8f14a90b0b352bd827ed215728b993b9ecf03c7c5e73bb0407b49ba15f9785fafa70f7e99a634e3624e8d2cad430c22278c3f40df473b78e59b775bc70d569c2d32f4c16e747fd053f22225d0dcae7f830aec47697368193a81485d5378cb6fb4e5f4fa60be074a9ef6dd76ad67113f11ba75df4e5fa52c87e249a29a2e033956ea98b5debca46e2dad0d8f06f42744c1eabd58bbbbce724edb0e59eabaaecac105084edc4466fe246c4c4a30f8db0839567defad2d3decfd2a6829bfae40ee68f5fe736f1eb49cf7060e0ae1f4f43beeda7ef6b7f5a5');
        var a = inflate.run(stored, 0, stored.length);
        var b = inflate.run(fixed, 0, fixed.length);
        Main.check(a != null && a.toString() == 'hello', 'inflate stored block');
        Main.check(b != null && b.toString() == 'hello world', 'inflate fixed block');
        // 600 random letters (zlib level 9: one dynamic block); length, sum and hash of the bytes
        var c = inflate.run(dyn, 0, dyn.length);
        var sum = 0;
        var hash = 0;
        if (c != null) {
            for (i in 0...c.length) {
                sum += c.get(i);
                hash = (hash * 31 + c.get(i)) & 0xFFFFFF;
            }
        }
        Main.check(c != null && c.length == 600 && sum == 62884 && hash == 8313072, 'inflate dynamic block');
        var bad = Bytes.ofHex('789c0000');
        Main.check(inflate.run(bad, 0, bad.length) == null, 'inflate rejects invalid data');
        Main.println('  ok   inflate (stored, fixed and dynamic blocks, invalid data)');
    }

    /** grey + alpha 16-bit PNG at its strike size: the generator's formula, high bytes */
    static function testSixteenBitPng():Void {
        var font = Font.fromBytes(Main.fontBytes('SbixTest.ttf'));
        var color = font.color();
        var out = new ColorBitmap();
        var gid = font.glyphForChar(0x1F603);
        var bad = 0;
        for (size in [20, 40]) {
            if (!color.rasterize(gid, size, 0, 0, out)) {
                bad++;
                continue;
            }
            var w = Std.int(size / 2);
            if (out.width != w || out.height != w || out.left != 3 || out.top != 4 + w)
                bad++;
            for (y in 0...w) {
                for (x in 0...w) {
                    var g = Std.int(65535 * x / (w - 1)) >> 8;
                    var a = Std.int(65535 * y / (w - 1)) >> 8;
                    var p = (y * w + x) * 4;
                    if (out.data.get(p) != g || out.data.get(p + 1) != g || out.data.get(p + 2) != g || out.data.get(p + 3) != a)
                        bad++;
                }
            }
        }
        Main.report('16-bit PNG (grey and alpha)', 2, bad > 0 ? 1 : 0);
    }

    /** Apple's `flip` glyphs: the referenced image mirrored horizontally */
    static function testFlip():Void {
        var font = Font.fromBytes(Main.fontBytes('SbixTest.ttf'));
        var color = font.color();
        var a = new ColorBitmap();
        var f = new ColorBitmap();
        var bad = 0;
        for (size in [20.0, 31.0, 40.0]) {
            color.rasterize(font.glyphForChar('A'.code), size, 0, 0, a);
            color.rasterize(font.glyphForChar(0x1F602), size, 0, 0, f);
            a.flipHorizontally();
            // Scaled sizes: mirroring before or after the resampling differs by rounding only
            if (a.width != f.width || a.height != f.height || a.left != f.left || a.top != f.top || maxDifference(a.data, f.data) > TOLERANCE)
                bad++;
        }
        Main.report('sbix flip glyphs', 3, bad);
    }

    static function maxDifference(a:Bytes, b:Bytes):Int {
        var max = 0;
        for (i in 0...a.length) {
            var d = a.get(i) - b.get(i);
            if (d < 0) d = -d;
            if (d > max) max = d;
        }
        return max;
    }

    static function testAstralCmap():Void {
        var bad = 0;
        for (file in ['SbixTest.ttf', 'CbdtTest.ttf', 'ColrTest.ttf']) {
            var font = Font.fromBytes(Main.fontBytes(file));
            if (font.glyphForChar(0x1F600) == 0)
                bad++;
        }
        Main.report('cmap format 12 (astral code points)', 3, bad);
    }

    /** `Font.fromSource()` reads only the directory and the small tables */
    static function testFromSource():Void {
        var bytes = Main.fontBytes('SbixTest.ttf');
        var reads = 0;
        var read = 0;
        var source = new FunctionFontSource(bytes.length, (offset, length) -> {
            reads++;
            read += length;
            return bytes.sub(offset, length);
        });
        var font = Font.fromSource(source, 0);
        var full = Font.fromBytes(bytes);
        var sbixLength = full.tableLength('sbix');
        var ok = Main.check(read < bytes.length - sbixLength + 64, 'fromSource reads the sbix table (${read} bytes of ${bytes.length})');
        ok = Main.check(font.numGlyphs == full.numGlyphs && font.familyName == full.familyName && font.metrics.ascent == full.metrics.ascent, 'fromSource metrics') && ok;
        ok = Main.check(font.hasTable('sbix') && font.table('sbix') == -1 && font.tableLength('sbix') == sbixLength, 'fromSource keeps sbix in the source') && ok;
        for (cp in [0x41, 0x1F600, 0x1F604])
            ok = Main.check(font.glyphForChar(cp) == full.glyphForChar(cp) && font.advance(font.glyphForChar(cp)) == full.advance(full.glyphForChar(cp)), 'fromSource cmap and advances') && ok;
        // Collections: the second face of a collection
        var ttc = Main.fontBytes('Collection-subset.ttc');
        var face1 = Font.fromSource(new BytesFontSource(ttc), 1);
        var full1 = Font.fromBytes(ttc, 1);
        ok = Main.check(face1.familyName == full1.familyName && face1.numGlyphs == full1.numGlyphs && face1.faceIndex == 1, 'fromSource collection face') && ok;
        var box = new ttf.GlyphBox();
        var box1 = new ttf.GlyphBox();
        var g = full1.glyphForChar('g'.code);
        face1.glyphBox(g, box);
        full1.glyphBox(g, box1);
        ok = Main.check(box.xMin == box1.xMin && box.yMax == box1.yMax, 'fromSource outlines') && ok;
        if (ok)
            Main.println('  ok   Font.fromSource (partial reads: $read of ${bytes.length} bytes in $reads reads)');
    }

}
