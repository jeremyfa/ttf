// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.atlas;

/**
 * A rectangle allocated in an atlas page. It stays valid while
 * `page.generation` equals `generation`.
 */
class AtlasRegion {

    public var page:AtlasPage = null;

    public var generation:Int = 0;

    public var x:Int = 0;

    public var y:Int = 0;

    public var width:Int = 0;

    public var height:Int = 0;

    public function new() {}

    /** False once the page has been evicted (cleared). */
    public inline function isValid():Bool {
        return page != null && page.generation == generation;
    }

}
