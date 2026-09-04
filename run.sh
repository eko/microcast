#!/bin/sh
# Build then launch the menu bar app.
set -eu
cd "$(dirname "$0")"
./build.sh
open build/MicroCast.app
