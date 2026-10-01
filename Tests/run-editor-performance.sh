#!/bin/bash
# Measures the normal editor on a file (see Tests/EditorPerformance.swift):  Tests/run-editor-performance.sh <file>
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
xcrun swiftc -O -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache \
  Tidepad/Models/*.swift Tidepad/Documents/*.swift Tidepad/Editor/*.swift Tidepad/Syntax/*.swift Tidepad/Utilities/*.swift \
  Tidepad/Storage/FileStamp.swift Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tests/EditorPerformance.swift -o build/EditorPerformance
build/EditorPerformance "$@"
