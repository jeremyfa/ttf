#!/bin/bash
# Runs the tests with the Haxe interpreter (eval).
# Usage: ./run-interp.sh [path-to-haxe]
set -eu
cd "$(dirname "$0")"
HAXE="${1:-${HAXE:-haxe}}"
"$HAXE" -cp src -cp ../src -cp ../../plutovg/src -main Main -D analyzer-optimize --interp
