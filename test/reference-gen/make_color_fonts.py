#!/usr/bin/env python3
# Original code, part of the ttf library for Ceramic.
# Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
#
# Builds the synthetic color test fonts of test/fonts (no download needed):
#   SbixTest.ttf   sbix strikes of 20 and 40 ppem: PNG images of every color type
#                  (RGBA 8, indexed 4-bit with tRNS, grey + alpha 16, interlaced RGB),
#                  origin offsets, a `dupe` and a `flip` glyph, astral code points
#                  (cmap format 12)
#   CbdtTest.ttf   CBLC / CBDT: two strikes (index formats 1 and 3, image formats 17 and 18)
#   ColrTest.ttf   COLR v0 + CPAL: layered glyphs, one layer with the text color
#
# Usage: make_color_fonts.py <out dir>
import os
import struct
import sys
import zlib

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.DefaultTable import DefaultTable
from fontTools.ttLib.tables import sbixStrike, sbixGlyph
from fontTools.colorLib.builder import buildCOLR, buildCPAL


# PNG encoding

def png_chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)


def png(width, height, color_type, depth, rows, palette=None, trns=None, interlace=0):
    """rows: list of byte strings (already packed samples, without the filter byte)"""
    raw = b''
    if interlace:
        raw = rows  # already the interlaced stream
    else:
        for i, row in enumerate(rows):
            # Cycle through the filter types: the decoder must handle all of them
            raw += filter_row(i % 5, row, rows[i - 1] if i > 0 else bytes(len(row)), bpp_bytes(color_type, depth))
    data = b'\x89PNG\r\n\x1a\n'
    data += png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color_type, 0, 0, interlace))
    if palette is not None:
        data += png_chunk(b'PLTE', palette)
    if trns is not None:
        data += png_chunk(b'tRNS', trns)
    comp = zlib.compress(raw, 9)
    # Two IDAT chunks, to test concatenation
    half = len(comp) // 2
    data += png_chunk(b'IDAT', comp[:half]) + png_chunk(b'IDAT', comp[half:])
    data += png_chunk(b'IEND', b'')
    return data


def bpp_bytes(color_type, depth):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    return max(1, (channels * depth + 7) // 8)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def filter_row(ftype, row, prev, bpp):
    out = bytearray([ftype])
    for i in range(len(row)):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        if ftype == 0:
            v = row[i]
        elif ftype == 1:
            v = row[i] - a
        elif ftype == 2:
            v = row[i] - b
        elif ftype == 3:
            v = row[i] - ((a + b) >> 1)
        else:
            v = row[i] - paeth(a, b, c)
        out.append(v & 0xFF)
    return bytes(out)


def rgba_pixel(x, y, w, h):
    """A gradient disc: transparent corners, partial alpha on the rim"""
    cx, cy = (w - 1) / 2, (h - 1) / 2
    d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / (w / 2)
    a = 255 if d < 0.8 else (0 if d > 1 else int(255 * (1 - d) / 0.2))
    return (int(255 * x / (w - 1)), int(255 * y / (h - 1)), 128, a)


def png_rgba(w, h):
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            row += bytes(rgba_pixel(x, y, w, h))
        rows.append(bytes(row))
    return png(w, h, 6, 8, rows)


def png_indexed(w, h):
    palette = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])
    trns = bytes([255, 128, 0])  # entry 3 opaque (implicit)
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(0, w, 2):
            i1 = ((x // 3) + y) % 4
            i2 = (((x + 1) // 3) + y) % 4
            row.append((i1 << 4) | i2)
        rows.append(bytes(row))
    return png(w, h, 3, 4, rows, palette=palette, trns=trns)


def png_grey16(w, h):
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            g = int(65535 * x / (w - 1))
            a = int(65535 * y / (h - 1))
            row += struct.pack('>HH', g, a)
        rows.append(bytes(row))
    return png(w, h, 4, 16, rows)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def png_interlaced_rgb(w, h):
    def pixel(x, y):
        return bytes([(x * 37) & 0xFF, (y * 53) & 0xFF, ((x + y) * 11) & 0xFF])
    stream = b''
    for (x0, y0, dx, dy) in ADAM7:
        xs = list(range(x0, w, dx))
        ys = list(range(y0, h, dy))
        if not xs or not ys:
            continue
        prev = bytes(len(xs) * 3)
        for i, y in enumerate(ys):
            row = b''.join(pixel(x, y) for x in xs)
            stream += filter_row((i + y) % 5, row, prev, 3)
            prev = row
    return png(w, h, 2, 8, stream, interlace=1)


# Fonts

def box_glyph(x0, y0, x1, y1):
    pen = TTGlyphPen(None)
    pen.moveTo((x0, y0))
    pen.lineTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.closePath()
    return pen.glyph()


def triangle_glyph(x0, y0, x1, y1):
    pen = TTGlyphPen(None)
    pen.moveTo((x0, y0))
    pen.qCurveTo(((x0 + x1) // 2, y1 + 100), (x1, y0))
    pen.closePath()
    return pen.glyph()


def set_metrics(fb, names, upem):
    # Left side bearings equal to the glyph xMin, like font compilers write them
    glyf = fb.font['glyf']
    metrics = {}
    for n in names:
        g = glyf[n]
        g.recalcBounds(glyf)
        metrics[n] = (upem, getattr(g, 'xMin', 0) if g.numberOfContours else 0)
    fb.setupHorizontalMetrics(metrics)


def base_font(names, cmap, family, upem=1000):
    fb = FontBuilder(upem, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap(cmap)
    glyphs = {}
    for name in names:
        if name in ('space', 'zwj'):
            glyphs[name] = TTGlyphPen(None).glyph()
        else:
            glyphs[name] = box_glyph(50, -100, upem - 50, upem - 200)
    fb.setupGlyf(glyphs)
    set_metrics(fb, names, upem)
    fb.setupHorizontalHeader(ascent=upem - 200, descent=-200)
    fb.setupNameTable({'familyName': family, 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=upem - 200, sTypoDescender=-200, usWinAscent=upem - 200, usWinDescent=200)
    fb.setupPost()
    return fb


def make_sbix(out_path):
    names = ['.notdef', 'space', 'A', 'smile', 'dupeA', 'flipA', 'grey', 'inter']
    cmap = {0x20: 'space', 0x41: 'A', 0x1F600: 'smile', 0x1F601: 'dupeA', 0x1F602: 'flipA',
            0x1F603: 'grey', 0x1F604: 'inter'}
    fb = base_font(names, cmap, 'Sbix Test', 1000)
    font = fb.font
    sbix = newTable('sbix')
    sbix.version = 1
    sbix.flags = 1
    for ppem in (20, 40):
        strike = sbixStrike.Strike(ppem=ppem, resolution=72)
        def add(name, data, gtype='png ', ox=0, oy=0, ref=None):
            glyph = sbixGlyph.Glyph(glyphName=name, graphicType=gtype, imageData=data,
                                    originOffsetX=ox, originOffsetY=oy)
            glyph.referenceGlyphName = ref
            strike.glyphs[name] = glyph
        s = ppem
        add('A', png_rgba(s, s), ox=1 if ppem == 20 else 2, oy=-3 if ppem == 20 else -6)
        add('smile', png_indexed(s, s - 2))
        add('dupeA', None, gtype='dupe', ref='A')
        add('flipA', None, gtype='flip', ref='A')
        add('grey', png_grey16(s // 2, s // 2), ox=3, oy=4)
        if ppem == 40:
            # Only in the large strike: smaller sizes scale it down
            add('inter', png_interlaced_rgb(37, 29))
        for name in names:
            if name not in strike.glyphs:
                strike.glyphs[name] = sbixGlyph.Glyph(glyphName=name)
        sbix.strikes[ppem] = strike
    font['sbix'] = sbix
    font.save(out_path)


def make_cbdt(out_path):
    names = ['.notdef', 'space', 'A', 'smile', 'grey', 'B']
    cmap = {0x20: 'space', 0x41: 'A', 0x1F600: 'smile', 0x1F603: 'grey', 0x42: 'B'}
    fb = base_font(names, cmap, 'Cbdt Test', 2048)
    font = fb.font
    # Glyphs 2 to 4 have images; 5 (B) has none
    first, last = 2, 4
    images = {
        16: [png_rgba(16, 16), png_indexed(16, 14), png_grey16(8, 8)],
        48: [png_rgba(48, 48), png_indexed(48, 46), png_grey16(24, 24)],
    }
    metrics = {
        16: [(1, 13, 17), (0, 12, 16), (2, 10, 12)],  # bearingX, bearingY, advance
        48: [(3, 40, 50), (0, 38, 48), (6, 30, 36)],
    }
    cbdt = bytearray(struct.pack('>HH', 3, 0))
    sizes = []
    for ppem, image_format, index_format in ((16, 17, 1), (48, 18, 3)):
        offsets = []
        image_offset = len(cbdt)
        for k, data in enumerate(images[ppem]):
            offsets.append(len(cbdt) - image_offset)
            w = struct.unpack('>I', data[16:20])[0]
            h = struct.unpack('>I', data[20:24])[0]
            bx, by, adv = metrics[ppem][k]
            if image_format == 17:
                cbdt += struct.pack('>BBbbB', h, w, bx, by, adv)
            else:
                cbdt += struct.pack('>BBbbBbbB', h, w, bx, by, adv, 0, 0, 0)
            cbdt += struct.pack('>I', len(data)) + data
            if index_format == 3 and len(cbdt) % 2:
                cbdt += b'\0'
        offsets.append(len(cbdt) - image_offset)
        sizes.append((ppem, image_format, index_format, image_offset, offsets))
    # CBLC: header, bitmap size records, then one index subtable array per size
    cblc = bytearray(struct.pack('>HHI', 3, 0, len(sizes)))
    records_at = len(cblc)
    cblc += bytes(48 * len(sizes))
    for i, (ppem, image_format, index_format, image_offset, offsets) in enumerate(sizes):
        array_at = len(cblc)
        # One IndexSubTableArray entry, the subtable right after it
        cblc += struct.pack('>HHI', first, last, 8)
        sub = struct.pack('>HHI', index_format, image_format, image_offset)
        if index_format == 1:
            sub += b''.join(struct.pack('>I', o) for o in offsets)
        else:
            sub += b''.join(struct.pack('>H', o) for o in offsets)
            if len(sub) % 4:
                sub += b'\0\0'
        cblc += sub
        line = struct.pack('>bbBbbbbbbbbb', ppem * 3 // 4, -(ppem // 4), ppem, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        rec = struct.pack('>IIII', array_at, len(cblc) - array_at, 1, 0) + line + line
        rec += struct.pack('>HHBBBb', first, last, ppem, ppem, 32, 1)
        assert len(rec) == 48
        cblc[records_at + i * 48:records_at + (i + 1) * 48] = rec
    for tag, data in (('CBDT', cbdt), ('CBLC', cblc)):
        table = DefaultTable(tag)
        table.data = bytes(data)
        font[tag] = table
    font.save(out_path)


def make_colr(out_path):
    names = ['.notdef', 'space', 'A', 'smile', 'layerBox', 'layerTri', 'layerDot', 'flag']
    # U+00E9 shares the 'A' glyph: a character a text font (Inter) maps too
    cmap = {0x20: 'space', 0x41: 'A', 0xE9: 'A', 0x1F600: 'smile', 0x1F1EB: 'flag'}
    fb = base_font(names, cmap, 'Colr Test', 1000)
    glyf = fb.font['glyf']
    glyf['layerBox'] = box_glyph(60, -120, 940, 760)
    glyf['layerTri'] = triangle_glyph(150, 100, 850, 650)
    glyf['layerDot'] = box_glyph(420, 300, 580, 460)
    fb.font['glyf'] = glyf
    set_metrics(fb, names, 1000)
    # Three layers for 'smile' (the dot with the text color), two for 'flag'
    colr = buildCOLR({
        'smile': [('layerBox', 0), ('layerTri', 1), ('layerDot', 0xFFFF)],
        'flag': [('layerTri', 2), ('layerDot', 3)],
    }, version=0)
    cpal = buildCPAL([
        [(1.0, 0.8, 0.0, 1.0), (0.2, 0.4, 1.0, 0.8), (0.0, 0.6, 0.2, 1.0), (1.0, 1.0, 1.0, 0.5)],
        [(0.0, 0.0, 0.0, 1.0), (1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0), (0.5, 0.5, 0.5, 1.0)],
    ])
    fb.font['COLR'] = colr
    fb.font['CPAL'] = cpal
    fb.font.save(out_path)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'fonts'
    make_sbix(os.path.join(out, 'SbixTest.ttf'))
    make_cbdt(os.path.join(out, 'CbdtTest.ttf'))
    make_colr(os.path.join(out, 'ColrTest.ttf'))


if __name__ == '__main__':
    main()
