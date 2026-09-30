#!/bin/bash
# Builds and runs the large-file spike (see Tests/LargeFileSpike.swift):
#   Tests/run-large-file-spike.sh index | textkit2 [--stay] | clone | scroll [--height N]   [--mb 500] [--file path]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
xcrun swiftc -O -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache \
  Tidepad/Storage/MappedUTF8Text.swift Tidepad/Storage/PieceTable.swift Tests/LargeFileSpike.swift -o build/LargeFileSpike
build/LargeFileSpike "$@"
