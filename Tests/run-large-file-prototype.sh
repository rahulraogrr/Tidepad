#!/bin/bash
# Builds and runs the large-file prototype (see Tests/LargeFilePrototype.swift).
#   Tests/run-large-file-prototype.sh                 500 MB, PieceTableTextStorage, TextKit 1
#   Tests/run-large-file-prototype.sh --textkit2      same with TextKit 2
#   Tests/run-large-file-prototype.sh --standard --mb 50   today's approach, for comparison
#   add --stay to keep the window open and try it by hand
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
xcrun swiftc -O -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache \
  Tidepad/Storage/MappedUTF8Text.swift Tidepad/Storage/PieceTable.swift Tidepad/Storage/PieceTableString.swift \
  Tidepad/Storage/PieceTableTextStorage.swift Tests/LargeFilePrototype.swift -o build/LargeFilePrototype
build/LargeFilePrototype "$@"
