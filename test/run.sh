#!/bin/bash
# Builds the tests with Haxe and runs them with Node.js.
# Usage: ./run.sh [path-to-haxe]
# The plutovg library is expected next to this one (../../plutovg).
set -eu
cd "$(dirname "$0")"
HAXE="${1:-${HAXE:-haxe}}"
"$HAXE" build.hxml
node bin/test.js "${@:2}"
