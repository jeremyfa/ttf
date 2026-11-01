// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.shape;

/**
 * The set of OpenType features applied by the shaper.
 *
 * Defaults match what HarfBuzz enables for horizontal Latin, Greek and
 * Cyrillic text: `ccmp`, `locl`, `rlig`, `rclt`, `calt`, `clig`, `liga`
 * for substitutions and `kern`, `mark`, `mkmk`, `dist`, `abvm`, `blwm`
 * for positioning.
 *
 * ```haxe
 * var noLigatures = Features.DEFAULT.with('liga', false).with('calt', false);
 * ```
 */
class Features {

    // Declared first: statics are initialized in declaration order
    static var nextId:Int = 0;

    static final GSUB_DEFAULTS = ['ccmp', 'locl', 'rlig', 'rclt', 'calt', 'clig', 'liga'];

    static final GPOS_DEFAULTS = ['kern', 'mark', 'mkmk', 'dist', 'abvm', 'blwm'];

    public static final DEFAULT:Features = new Features(GSUB_DEFAULTS.copy(), GPOS_DEFAULTS.copy());

    /** Unique id, used to cache lookup lists per feature set. */
    public var id(default, null):Int;

    /** Substitution features (`GSUB`). */
    public var gsub(default, null):Array<String>;

    /** Positioning features (`GPOS`). */
    public var gpos(default, null):Array<String>;

    /** True when `kern` is enabled (also used for the legacy `kern` table). */
    public var kerning(default, null):Bool;

    public function new(gsub:Array<String>, gpos:Array<String>) {
        this.id = nextId++;
        this.gsub = gsub;
        this.gpos = gpos;
        this.kerning = gpos.indexOf('kern') >= 0;
    }

    /**
     * Returns a copy with `tag` enabled or disabled. Unknown tags are
     * added to `GSUB` features unless they are known positioning features.
     */
    public function with(tag:String, enabled:Bool):Features {
        var g = gsub.copy();
        var p = gpos.copy();
        g.remove(tag);
        p.remove(tag);
        if (enabled) {
            if (GPOS_DEFAULTS.indexOf(tag) >= 0 || tag == 'cpsp' || tag == 'curs')
                p.push(tag);
            else
                g.push(tag);
        }
        return new Features(g, p);
    }

}
