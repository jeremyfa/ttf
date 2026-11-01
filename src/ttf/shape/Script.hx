// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.shape;

/**
 * Minimal script detection, used to select the OpenType script of a run.
 * Only the scripts handled by the simple shaper are recognized; other
 * characters are `COMMON` and inherit the script of their neighbours.
 */
class Script {

    public static inline var COMMON = 0;
    public static inline var LATIN = 1;
    public static inline var GREEK = 2;
    public static inline var CYRILLIC = 3;
    public static inline var OTHER = 4;

    public static function of(c:Int):Int {
        if (c < 0x41)
            return COMMON;
        if (c <= 0x7A)
            return ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) ? LATIN : COMMON;
        if (c < 0xC0)
            return (c == 0xAA || c == 0xBA) ? LATIN : COMMON;
        if (c <= 0x24F)
            return (c == 0xD7 || c == 0xF7) ? COMMON : LATIN;
        if (c >= 0x250 && c <= 0x2AF) return LATIN;
        if (c >= 0x300 && c <= 0x36F) return COMMON;
        if (c >= 0x370 && c <= 0x3FF) return GREEK;
        if (c >= 0x400 && c <= 0x52F) return CYRILLIC;
        if (c >= 0x1D00 && c <= 0x1DBF) return LATIN;
        if (c >= 0x1E00 && c <= 0x1EFF) return LATIN;
        if (c >= 0x1F00 && c <= 0x1FFF) return GREEK;
        if (c >= 0x2000 && c <= 0x2BFF) return COMMON;
        if (c >= 0x2C60 && c <= 0x2C7F) return LATIN;
        if (c >= 0x2DE0 && c <= 0x2DFF) return CYRILLIC;
        if (c >= 0xA640 && c <= 0xA69F) return CYRILLIC;
        if (c >= 0xA720 && c <= 0xA7FF) return LATIN;
        if (c >= 0xAB30 && c <= 0xAB6F) return LATIN;
        if (c >= 0xFB00 && c <= 0xFB06) return LATIN;
        if (c >= 0xFE00 && c <= 0xFE0F) return COMMON;
        if (c >= 0xFF21 && c <= 0xFF3A) return LATIN;
        if (c >= 0xFF41 && c <= 0xFF5A) return LATIN;
        if (c >= 0x3000 && c <= 0x303F) return COMMON;
        if (c >= 0x1F000 && c <= 0x1FAFF) return COMMON;
        return OTHER;
    }

    /** OpenType script tag. */
    public static function tag(script:Int):String {
        return switch script {
            case LATIN: 'latn';
            case GREEK: 'grek';
            case CYRILLIC: 'cyrl';
            default: 'DFLT';
        }
    }

}
