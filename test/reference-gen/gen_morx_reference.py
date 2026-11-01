#!/usr/bin/env python3
# Original code, part of the ttf library for Ceramic.
# Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
#
# Shapes emoji sequences with Apple Color Emoji (its `morx` table) using
# HarfBuzz's hb-shape, as reference data for the ttf morx support
# (test/reference/morx.json). macOS only: the font is a system font.
#
# Usage (from test/): python3 reference-gen/gen_morx_reference.py > reference/morx.json
import json
import subprocess

FONT = '/System/Library/Fonts/Apple Color Emoji.ttc'

TEXTS = [
    '\U0001F600',                                   # single emoji
    '\U0001F468‍\U0001F469‍\U0001F467',   # family (ZWJ)
    '\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466',
    '\U0001F44D\U0001F3FD',                         # skin tone
    '\U0001F469\U0001F3FD‍\U0001F4BB',         # skin tone + profession
    '\U0001F1EB\U0001F1F7',                         # flag
    '\U0001F1EF\U0001F1F5\U0001F1FA\U0001F1F8',     # two flags
    '\U0001F1EB',                                   # lone regional indicator
    '1️⃣',                                # keycap
    '#️⃣',
    '❤️',                                 # variation selector 16
    '❤️‍\U0001F525',                 # heart on fire
    '\U0001F3F3️‍\U0001F308',             # rainbow flag
    '\U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F',  # Scotland
    '\U0001F3C3‍➡️',                 # person running facing right (flip)
    '\U0001F9D1\U0001F3FB‍\U0001F91D‍\U0001F9D1\U0001F3FF',  # people holding hands, two tones
    '\U0001F600\U0001F44D\U0001F3FD\U0001F1EB\U0001F1F7\U0001F468‍\U0001F469‍\U0001F467',
    '\U0001F441️‍\U0001F5E8️',       # eye in speech bubble
]


# Emoji sequences shaped with a font without emoji: the clusters of the
# sequences (HarfBuzz groups them, `hb_set_unicode_props`)
CLUSTER_TEXTS = [
    'a\U0001F1EB\U0001F1F7\U0001F1EF\U0001F1F5b',
    '\U0001F468\u200D\U0001F469\u200D\U0001F467x',
    '\U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F',
    'x\u200Dy',
    '\U0001F44D\U0001F3FD!',
]


def shape(font, text):
    out = subprocess.run(['hb-shape', '--face-index=0', '--no-glyph-names', '--output-format=json',
                          '--no-positions', '--utf8-clusters', font, text],
                         capture_output=True, text=True, check=True).stdout
    glyphs = json.loads(out)
    return {'text': text, 'glyphs': [g['g'] for g in glyphs], 'clusters': [g['cl'] for g in glyphs]}


def main():
    version = subprocess.run(['hb-shape', '--version'], capture_output=True, text=True).stdout.split('\n')[0]
    cases = [shape(FONT, text) for text in TEXTS]
    clusters = [shape('fonts/Inter-Regular.ttf', text) for text in CLUSTER_TEXTS]
    print(json.dumps({'tool': version, 'font': FONT, 'cases': cases, 'clusterFont': 'Inter-Regular.ttf',
                      'clusterCases': clusters}, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
