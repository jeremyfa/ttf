// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.

import haxe.io.Bytes;

/**
 * Minimal file reading for the test runner (Node.js or sys targets).
 */
class Fs {

    public static function getText(path:String):String {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        return fs.readFileSync(path, 'utf8');
        #else
        return sys.io.File.getContent(path);
        #end
    }

    public static function getBytes(path:String):Bytes {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        var buf:Dynamic = fs.readFileSync(path);
        var array = new js.lib.Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        var bytes = Bytes.alloc(array.length);
        for (i in 0...array.length)
            bytes.set(i, array[i]);
        return bytes;
        #else
        return sys.io.File.getBytes(path);
        #end
    }

    public static function saveBytes(path:String, bytes:Bytes):Void {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        var buffer:Dynamic = js.Syntax.code('Buffer.from({0})', bytes.getData());
        fs.writeFileSync(path, buffer);
        #else
        sys.io.File.saveBytes(path, bytes);
        #end
    }

    public static function exists(path:String):Bool {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        return fs.existsSync(path);
        #else
        return sys.FileSystem.exists(path);
        #end
    }

    public static function fileSize(path:String):Int {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        return fs.statSync(path).size;
        #else
        return sys.FileSystem.stat(path).size;
        #end
    }

    /** Reads `length` bytes at `offset` of a file (for `ttf.FontSource`) */
    public static function readRange(path:String, offset:Int, length:Int):Bytes {
        #if js
        var fs:Dynamic = js.Lib.require('fs');
        var fd:Dynamic = fs.openSync(path, 'r');
        var buf:Dynamic = js.Syntax.code('Buffer.alloc({0})', length);
        var n:Int = fs.readSync(fd, buf, 0, length, offset);
        fs.closeSync(fd);
        return Bytes.ofData(js.Syntax.code('{0}.buffer.slice({0}.byteOffset, {0}.byteOffset + {1})', buf, n));
        #else
        var input = sys.io.File.read(path, true);
        input.seek(offset, SeekBegin);
        var bytes = input.read(length);
        input.close();
        return bytes;
        #end
    }

    public static function stamp():Float {
        #if js
        return js.Syntax.code('Number(process.hrtime.bigint()) / 1e9');
        #else
        return Sys.time();
        #end
    }

}
