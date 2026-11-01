#!/usr/bin/env python3
# Original code, part of the ttf library for Ceramic.
# Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
#
# Generates the reference data of test/reference from reference tools:
#   - fontTools: names, cmap, advances, outline control boxes and areas;
#   - HarfBuzz (uharfbuzz): font extents and shaping (default features);
#   - FreeType (freetype-py): unhinted grayscale glyph bitmaps.
#
# Usage (from test/): python3 reference-gen/gen_reference.py
# Requirements: pip install fonttools uharfbuzz freetype-py
import base64
import json
import os

import freetype
import uharfbuzz as hb
from fontTools.pens.areaPen import AreaPen
from fontTools.pens.boundsPen import ControlBoundsPen
from fontTools.ttLib import TTFont

FONTS = [
    ('Inter-Regular.ttf', 0),
    ('Inter-Regular.otf', 0),
    ('JetBrainsMono-Regular.ttf', 0),
    ('Inter-CFF2-subset.otf', 0),
    ('Collection-subset.ttc', 0),
    ('Collection-subset.ttc', 1),
    ('KernLigaTest.ttf', 0),
]

CMAP_CHARS = (list(range(0x20, 0x7F)) + list(range(0xA0, 0x180)) +
              [0x391, 0x3B1, 0x3C9, 0x410, 0x430, 0x44F, 0x2013, 0x2014, 0x2026, 0x20AC,
               0x2192, 0x2208, 0x211D, 0x2500, 0x4E00, 0x1F600, 0x10FFFF])

# Long dash, curly quotes and combining marks are built with chr() to keep this file ASCII only
LONG_DASH = chr(0x2014)
QUOTE_OPEN = chr(0x201C)
QUOTE_CLOSE = chr(0x201D)
ACUTE = chr(0x301)
DIAERESIS = chr(0x308)
ZWJ = chr(0x200D)

GREEK = ''.join(chr(c) for c in [0x39A, 0x3B1, 0x3BB, 0x3B7, 0x3BC, 0x3AD, 0x3C1, 0x3B1, 0x20,
                                 0x3BA, 0x3CC, 0x3C3, 0x3BC, 0x3B5])
CYRILLIC = ''.join(chr(c) for c in [0x41F, 0x440, 0x438, 0x432, 0x435, 0x442, 0x2C, 0x20,
                                    0x43C, 0x438, 0x440])
LATIN_ACCENTS = 'na' + chr(0xEF) + 've caf' + chr(0xE9) + ' d' + chr(0xE9) + 'j' + chr(0xE0) + ' vu'

SHAPING = {
    'Inter-Regular.ttf': [
        'Hello, World!', 'AVATAR Tokyo WAVE', 'Ta Te Yo LT.', 'office affine fluffy',
        '-> => != <= >= :: 1/2', GREEK, CYRILLIC, LATIN_ACCENTS,
        'q' + ACUTE + ' x' + DIAERESIS, 'The quick brown fox jumps over the lazy dog.', '(Hx) [Hy] {Hz}',
        'Wolf' + LONG_DASH + 'Kraft ' + QUOTE_OPEN + 'quoted' + QUOTE_CLOSE, '', ' ', 'A' + ZWJ + 'B',
    ],
    'Inter-Regular.otf': [
        'Hello, World!', 'AVATAR Tokyo WAVE', CYRILLIC, 'The quick brown fox jumps over the lazy dog.',
    ],
    'JetBrainsMono-Regular.ttf': [
        '-> => != === <= >= |> <!-- --> www', 'fi fl ffi', 'let x = a && b || c;', 'Hello, World!',
    ],
    'Inter-CFF2-subset.otf': ['Hello, World!', 'AVATAR WAVE'],
    'KernLigaTest.ttf': ['AVAT', 'To fi.', 'VoA fifi.'],
}

RASTER = {
    'Inter-Regular.ttf': 'AgQ&@8e%',
    'Inter-Regular.otf': 'AgQ&@8',
    'JetBrainsMono-Regular.ttf': 'Mg{0',
    'Inter-CFF2-subset.otf': 'Rg&',
    'KernLigaTest.ttf': 'AVo',
}
RASTER_SIZES = [(12, [0, 0.5]), (16, [0, 0.25, 0.5, 0.75]), (31.5, [0, 0.75])]


def names(font):
    name = font['name']
    family = name.getBestFamilyName() or ''
    style = name.getBestSubFamilyName() or ''
    return family, style


def metrics(path, index):
    font = TTFont(path, fontNumber=index)
    blob = hb.Blob.from_file_path(path)
    face = hb.Face(blob, index)
    hbfont = hb.Font(face)
    ext = hbfont.get_font_extents('ltr')
    os2 = font['OS/2'] if 'OS/2' in font else None
    head = font['head']
    post = font['post']
    family, style = names(font)
    return {
        'unitsPerEm': head.unitsPerEm,
        'numGlyphs': font['maxp'].numGlyphs,
        'ascent': ext.ascender,
        'descent': ext.descender,
        'lineGap': ext.line_gap,
        'underlinePosition': post.underlinePosition,
        'underlineThickness': post.underlineThickness,
        'capHeight': getattr(os2, 'sCapHeight', 0) if os2 else 0,
        'xHeight': getattr(os2, 'sxHeight', 0) if os2 else 0,
        'bbox': [head.xMin, head.yMin, head.xMax, head.yMax],
        'family': family,
        'style': style,
    }


def glyph_data(path, index):
    font = TTFont(path, fontNumber=index)
    cmap = font.getBestCmap()
    order = font.getGlyphOrder()
    gids = {name: i for i, name in enumerate(order)}
    glyph_set = font.getGlyphSet()
    hmtx = font['hmtx']

    cmap_list = [[c, gids[cmap[c]] if c in cmap else 0] for c in CMAP_CHARS]

    n = len(order)
    step = max(1, n // 400)
    sample = sorted(set(list(range(0, n, step)) + [gids[cmap[c]] for c in range(0x21, 0x7F) if c in cmap]))
    glyphs = []
    for gid in sample:
        name = order[gid]
        adv, lsb = hmtx[name]
        bp = ControlBoundsPen(glyph_set)
        glyph_set[name].draw(bp)
        ap = AreaPen(glyph_set)
        glyph_set[name].draw(ap)
        box = list(bp.bounds) if bp.bounds else [0, 0, 0, 0]
        glyphs.append([gid, adv, lsb] + [round(v, 4) for v in box] + [round(ap.value, 3)])
    return cmap_list, glyphs


def shape(path, index, text):
    blob = hb.Blob.from_file_path(path)
    face = hb.Face(blob, index)
    font = hb.Font(face)
    buf = hb.Buffer()
    buf.add_utf8(text.encode('utf-8'))
    buf.guess_segment_properties()
    hb.shape(font, buf, {})
    out = []
    pen = 0
    for info, pos in zip(buf.glyph_infos or [], buf.glyph_positions or []):
        out.append([info.codepoint, info.cluster, pen + pos.x_offset, pos.y_offset, pos.x_advance])
        pen += pos.x_advance
    return {'text': text, 'glyphs': out, 'width': pen}


def raster(path, index, gid, size, subx):
    face = freetype.Face(path, index)
    face.set_char_size(int(round(size * 64)), 0, 72, 72)
    matrix = freetype.Matrix(0x10000, 0, 0, 0x10000)
    delta = freetype.Vector(int(round(subx * 64)), 0)
    face.set_transform(matrix, delta)
    face.load_glyph(gid, freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP | freetype.FT_LOAD_RENDER)
    slot = face.glyph
    bm = slot.bitmap
    rows = []
    buf = bm.buffer
    for y in range(bm.rows):
        rows.append(bytes(buf[y * bm.pitch: y * bm.pitch + bm.width]))
    data = b''.join(rows)
    return {
        'gid': gid, 'size': size, 'subx': subx,
        'left': slot.bitmap_left, 'top': slot.bitmap_top,
        'width': bm.width, 'height': bm.rows,
        'data': base64.b64encode(data).decode('ascii'),
    }


def main():
    out_dir = 'reference'
    os.makedirs(out_dir, exist_ok=True)
    result = {'tools': {
        'harfbuzz': hb.version_string(),
        'freetype': '.'.join(str(v) for v in freetype.version()),
    }, 'fonts': []}
    for path, index in FONTS:
        full = os.path.join('fonts', path)
        entry = {'file': path, 'index': index, 'metrics': metrics(full, index)}
        cmap_list, glyphs = glyph_data(full, index)
        entry['cmap'] = cmap_list
        entry['glyphs'] = glyphs
        if index == 0 and path in SHAPING:
            entry['shaping'] = [shape(full, index, t) for t in SHAPING[path]]
        if index == 0 and path in RASTER:
            font = TTFont(full)
            cmap = font.getBestCmap()
            order = font.getGlyphOrder()
            rasters = []
            for ch in RASTER[path]:
                gid = order.index(cmap[ord(ch)])
                for size, subs in RASTER_SIZES:
                    for subx in subs:
                        rasters.append(raster(full, index, gid, size, subx))
            entry['raster'] = rasters
        result['fonts'].append(entry)
    with open(os.path.join(out_dir, 'reference.json'), 'w') as f:
        json.dump(result, f, separators=(',', ':'), ensure_ascii=True)


if __name__ == '__main__':
    main()
