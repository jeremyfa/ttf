// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.atlas;

import haxe.io.Bytes;

/**
 * A dynamic atlas of 8-bit coverage images (glyph bitmaps), spread over
 * pages of a fixed size.
 *
 * Allocation uses shelf packing (`ShelfAllocator`) with `padding` empty
 * pixels around each image. When every page is full, a new page is added
 * until `maxPages` is reached. After that, the least recently used page
 * (see `frame` and `touch()`) is evicted: it is cleared, its `generation`
 * is incremented (so its `AtlasRegion`s become invalid) and
 * `onPageEvicted` is called so that caches can forget the glyphs it held.
 * With `maxPages = 0` (the default), pages are never evicted.
 *
 * The atlas only works on the CPU side: renderers upload the modified
 * area of each page (`AtlasPage.isDirty()`, `dirtyMinX`...) and then call
 * `clearDirty()`.
 */
class GlyphAtlas {

    public var pageWidth(default, null):Int;

    public var pageHeight(default, null):Int;

    /** Maximum number of pages, 0 for no limit (no eviction). */
    public var maxPages:Int;

    /** Empty pixels kept around each image. */
    public var padding:Int;

    public var pages(default, null):Array<AtlasPage> = [];

    /** Current frame (or any increasing counter), used for LRU eviction. */
    public var frame:Int = 0;

    /** Called after a page has been cleared to make room. */
    public var onPageEvicted:(AtlasPage) -> Void = null;

    /** Called when a page is created. */
    public var onPageCreated:(AtlasPage) -> Void = null;

    public function new(pageWidth:Int = 1024, pageHeight:Int = 1024, maxPages:Int = 0, padding:Int = 1) {
        this.pageWidth = pageWidth;
        this.pageHeight = pageHeight;
        this.maxPages = maxPages;
        this.padding = padding;
    }

    /** Marks a page as used during the current frame. */
    public inline function touch(page:AtlasPage):Void {
        page.lastUse = frame;
    }

    /**
     * Allocates a `width` x `height` region. Returns null only if the image
     * is larger than a page.
     */
    public function allocate(width:Int, height:Int, ?out:AtlasRegion):AtlasRegion {

        var pw = width + padding * 2;
        var ph = height + padding * 2;
        if (pw > pageWidth || ph > pageHeight)
            return null;

        var region = out != null ? out : new AtlasRegion();

        // Most recent pages first: older ones are likely full
        var i = pages.length - 1;
        while (i >= 0) {
            var page = pages[i];
            if (page.allocator.allocate(pw, ph))
                return fill(region, page, width, height);
            i--;
        }

        if (maxPages <= 0 || pages.length < maxPages) {
            var page = addPage();
            if (page.allocator.allocate(pw, ph))
                return fill(region, page, width, height);
            return null;
        }

        // Evict the least recently used page
        var lru = pages[0];
        for (p in pages) {
            if (p.lastUse < lru.lastUse)
                lru = p;
        }
        lru.reset();
        if (onPageEvicted != null)
            onPageEvicted(lru);
        if (lru.allocator.allocate(pw, ph))
            return fill(region, lru, width, height);
        return null;

    }

    /**
     * Adds an empty page (allocation does it automatically when needed).
     */
    public function addPage():AtlasPage {
        var page = new AtlasPage(pages.length, pageWidth, pageHeight);
        pages.push(page);
        if (onPageCreated != null)
            onPageCreated(page);
        return page;
    }

    function fill(region:AtlasRegion, page:AtlasPage, width:Int, height:Int):AtlasRegion {
        region.page = page;
        region.generation = page.generation;
        region.x = page.allocator.x + padding;
        region.y = page.allocator.y + padding;
        region.width = width;
        region.height = height;
        page.lastUse = frame;
        return region;
    }

    /**
     * Copies coverage values into an allocated region and marks it dirty.
     */
    public function write(region:AtlasRegion, src:Bytes, srcOffset:Int, srcStride:Int):Void {
        var page = region.page;
        var dst = page.data;
        var w = region.width;
        for (row in 0...region.height) {
            dst.blit((region.y + row) * page.width + region.x, src, srcOffset + row * srcStride, w);
        }
        page.markDirty(region.x, region.y, w, region.height);
    }

    /** Removes every page content (pages are kept). */
    public function clear():Void {
        for (page in pages) {
            page.reset();
            if (onPageEvicted != null)
                onPageEvicted(page);
        }
    }

}
