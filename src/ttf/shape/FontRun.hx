// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.shape;

/**
 * A range of text (in UTF-8 bytes) shaped with a font, like GPUI's
 * `FontRun`. Characters missing from `font` are looked up in `fallbacks`,
 * in order.
 */
class FontRun {

    /** Length of the run in UTF-8 bytes. */
    public var len:Int;

    public var font:ttf.Font;

    /** Fonts used for characters that `font` does not map (can be null). */
    public var fallbacks:Null<Array<ttf.Font>>;

    /** OpenType features (null means `Features.DEFAULT`). */
    public var features:Null<Features>;

    public function new(len:Int, font:ttf.Font, ?fallbacks:Array<ttf.Font>, ?features:Features) {
        this.len = len;
        this.font = font;
        this.fallbacks = fallbacks;
        this.features = features;
    }

}
