#!/bin/bash
# Builds the tests with hxcpp and runs them.
# Usage: ./run-cpp.sh <path-to-hxcpp> [path-to-haxe] [path-to-haxelib]
# A local haxelib repository (.haxelib) is created in this directory so that
# nothing is changed globally.
set -eu
cd "$(dirname "$0")"
HXCPP_DIR="${1:?usage: run-cpp.sh <path-to-hxcpp> [haxe] [haxelib]}"
HAXE="${2:-haxe}"
HAXELIB="${3:-haxelib}"
if [ ! -d .haxelib ]; then
    "$HAXELIB" newrepo
fi
"$HAXELIB" dev hxcpp "$HXCPP_DIR"
"$HAXE" build-cpp.hxml
./bin/cpp/Main
