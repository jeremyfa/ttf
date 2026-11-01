// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.atlas;

import haxe.io.Bytes;

/**
 * A page of a `GlyphAtlas`: an 8-bit coverage image plus its allocator and
 * the rectangle modified since the last upload.
 */
class AtlasPage {

    /** Index of the page in its atlas. */
    public var index(default, null):Int;

    public var width(default, null):Int;

    public var height(default, null):Int;

    /** Coverage values, one byte per pixel, `width` bytes per row. */
    public var data(default, null):Bytes;

    public var allocator(default, null):ShelfAllocator;

    /** Incremented every time the page is cleared (eviction). */
    public var generation(default, null):Int = 0;

    /** Value of `GlyphAtlas.frame` when the page was last used. */
    public var lastUse:Int = 0;

    /** Modified area (inclusive min, exclusive max), empty when `dirtyMaxX <= dirtyMinX`. */
    public var dirtyMinX(default, null):Int = 0;
    public var dirtyMinY(default, null):Int = 0;
    public var dirtyMaxX(default, null):Int = 0;
    public var dirtyMaxY(default, null):Int = 0;

    public function new(index:Int, width:Int, height:Int) {
        this.index = index;
        this.width = width;
        this.height = height;
        data = Bytes.alloc(width * height);
        data.fill(0, width * height, 0);
        allocator = new ShelfAllocator(width, height);
    }

    public inline function isDirty():Bool {
        return dirtyMaxX > dirtyMinX && dirtyMaxY > dirtyMinY;
    }

    public function markDirty(x:Int, y:Int, w:Int, h:Int):Void {
        if (!isDirty()) {
            dirtyMinX = x;
            dirtyMinY = y;
            dirtyMaxX = x + w;
            dirtyMaxY = y + h;
        }
        else {
            if (x < dirtyMinX) dirtyMinX = x;
            if (y < dirtyMinY) dirtyMinY = y;
            if (x + w > dirtyMaxX) dirtyMaxX = x + w;
            if (y + h > dirtyMaxY) dirtyMaxY = y + h;
        }
    }

    /** Forgets the modified area (call after uploading it). */
    public function clearDirty():Void {
        dirtyMinX = dirtyMinY = dirtyMaxX = dirtyMaxY = 0;
    }

    /** Clears every pixel and allocation (the whole page becomes dirty). */
    public function reset():Void {
        data.fill(0, width * height, 0);
        allocator.reset();
        generation++;
        markDirty(0, 0, width, height);
    }

}
