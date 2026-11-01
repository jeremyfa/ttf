// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf;

import haxe.io.Bytes;

/** A range of a font table: its bytes start at `pos` in `bytes` (see `Font.readTable()`). */
class TableRange {

    public var bytes:Bytes = null;

    public var pos:Int = 0;

    public function new() {}

}
