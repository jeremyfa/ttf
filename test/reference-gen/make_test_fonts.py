#!/usr/bin/env python3
# Original code, part of the ttf library for Ceramic.
# Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
#
# Builds the derived test fonts of test/fonts from the official releases:
#   - Inter 4.1: https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
#   - JetBrains Mono 2.304: https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
#
# Usage: make_test_fonts.py <Inter-Regular.ttf> <Inter-Regular.otf> <JetBrainsMono-Regular.ttf> <out dir>
#
# Outputs:
#   Inter-Regular.ttf, Inter-Regular.otf, JetBrainsMono-Regular.ttf (copies)
#   Collection-subset.ttc   Inter + JetBrains Mono subset to ASCII, as a TrueType collection
#   Inter-CFF2-subset.otf   Inter (CFF) subset to ASCII and converted to CFF2
#   KernLigaTest.ttf        a synthetic font (boxes) with a legacy kern table and a GSUB liga feature
import shutil
import sys
import os

from fontTools.ttLib import TTFont, TTCollection
from fontTools import subset
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString


def subset_font(path, text):
    options = subset.Options()
    options.layout_features = ['*']
    options.name_IDs = ['*']
    options.notdef_outline = True
    font = TTFont(path)
    sub = subset.Subsetter(options)
    sub.populate(text=text)
    sub.subset(font)
    return font


def make_kern_liga(out_path):
    names = ['.notdef', 'space', 'A', 'V', 'T', 'o', 'f', 'i', 'period', 'f_i']
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({0x20: 'space', 0x41: 'A', 0x56: 'V', 0x54: 'T', 0x6F: 'o',
                          0x66: 'f', 0x69: 'i', 0x2E: 'period'})
    glyphs = {}
    widths = {'.notdef': 500, 'space': 250, 'A': 600, 'V': 600, 'T': 560, 'o': 520,
              'f': 320, 'i': 260, 'period': 240, 'f_i': 560}
    for name in names:
        pen = TTGlyphPen(None)
        if name != 'space':
            w = widths[name]
            top = 700 if name in ('A', 'V', 'T', 'f', 'f_i', '.notdef') else 500
            if name == 'period':
                top = 100
            # A box with an inner counter, plus a quadratic bump on top
            pen.moveTo((40, 0))
            pen.lineTo((40, top))
            pen.qCurveTo((w // 2, top + 80), (w - 40, top))
            pen.lineTo((w - 40, 0))
            pen.closePath()
            if top > 200:
                pen.moveTo((100, 60))
                pen.lineTo((w - 100, 60))
                pen.lineTo((w - 100, top - 60))
                pen.lineTo((100, top - 60))
                pen.closePath()
        glyphs[name] = pen.glyph()
    fb.setupGlyf(glyphs)
    metrics = {}
    for name in names:
        metrics[name] = (widths[name], 40 if name != 'space' else 0)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({'familyName': 'KernLigaTest', 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200,
                sxHeight=500, sCapHeight=700)
    fb.setupPost()
    fb.setupHead(unitsPerEm=1000)
    font = fb.font
    addOpenTypeFeaturesFromString(font, """
        languagesystem DFLT dflt;
        languagesystem latn dflt;
        feature liga { sub f i by f_i; } liga;
    """)
    # Legacy kern table (format 0)
    from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0, table__k_e_r_n
    kern = table__k_e_r_n()
    kern.version = 0
    sub = KernTable_format_0()
    sub.version = 0
    sub.coverage = 1
    sub.format = 0
    sub.kernTable = {('A', 'V'): -80, ('V', 'A'): -80, ('T', 'o'): -60, ('f_i', 'period'): -30, ('V', 'o'): -40}
    kern.kernTables = [sub]
    font['kern'] = kern
    font.save(out_path)


def main():
    inter_ttf, inter_otf, jbm_ttf, out = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    shutil.copyfile(inter_ttf, os.path.join(out, 'Inter-Regular.ttf'))
    shutil.copyfile(inter_otf, os.path.join(out, 'Inter-Regular.otf'))
    shutil.copyfile(jbm_ttf, os.path.join(out, 'JetBrainsMono-Regular.ttf'))

    ascii_text = ''.join(chr(c) for c in range(0x20, 0x7F))

    # TrueType collection of two ASCII subsets
    collection = TTCollection()
    collection.fonts = [subset_font(inter_ttf, ascii_text), subset_font(jbm_ttf, ascii_text)]
    collection.save(os.path.join(out, 'Collection-subset.ttc'))

    # CFF2 conversion of an ASCII subset of Inter (CFF)
    from fontTools.cffLib.CFFToCFF2 import convertCFFToCFF2
    cff2 = subset_font(inter_otf, ascii_text)
    convertCFFToCFF2(cff2)
    cff2.save(os.path.join(out, 'Inter-CFF2-subset.otf'))

    make_kern_liga(os.path.join(out, 'KernLigaTest.ttf'))


if __name__ == '__main__':
    main()
