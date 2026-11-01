// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
package ttf.layout;

import haxe.io.Bytes;
import ttf.Bin.*;

/**
 * Coverage and class definition lookups shared by `GDEF`, `GSUB` and `GPOS`.
 * Every offset is absolute (position in the font data).
 */
class OtCommon {

    /**
     * Returns the coverage index of `gid`, or -1 if it is not covered.
     */
    public static function coverageIndex(b:Bytes, cov:Int, gid:Int):Int {
        var format = u16(b, cov);
        if (format == 1) {
            var count = u16(b, cov + 2);
            var lo = 0;
            var hi = count - 1;
            while (lo <= hi) {
                var mid = (lo + hi) >> 1;
                var g = u16(b, cov + 4 + mid * 2);
                if (g < gid) lo = mid + 1;
                else if (g > gid) hi = mid - 1;
                else return mid;
            }
            return -1;
        }
        else if (format == 2) {
            var count = u16(b, cov + 2);
            var lo = 0;
            var hi = count - 1;
            while (lo <= hi) {
                var mid = (lo + hi) >> 1;
                var r = cov + 4 + mid * 6;
                var start = u16(b, r);
                var end = u16(b, r + 2);
                if (gid < start) hi = mid - 1;
                else if (gid > end) lo = mid + 1;
                else return u16(b, r + 4) + gid - start;
            }
            return -1;
        }
        return -1;
    }

    /**
     * Returns the class of `gid` in a class definition table (0 if not listed).
     */
    public static function classOf(b:Bytes, cd:Int, gid:Int):Int {
        if (cd <= 0)
            return 0;
        var format = u16(b, cd);
        if (format == 1) {
            var start = u16(b, cd + 2);
            var count = u16(b, cd + 4);
            if (gid >= start && gid < start + count)
                return u16(b, cd + 6 + (gid - start) * 2);
            return 0;
        }
        else if (format == 2) {
            var count = u16(b, cd + 2);
            var lo = 0;
            var hi = count - 1;
            while (lo <= hi) {
                var mid = (lo + hi) >> 1;
                var r = cd + 4 + mid * 6;
                var start = u16(b, r);
                var end = u16(b, r + 2);
                if (gid < start) hi = mid - 1;
                else if (gid > end) lo = mid + 1;
                else return u16(b, r + 4);
            }
            return 0;
        }
        return 0;
    }

}
