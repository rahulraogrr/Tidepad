#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(xcrun --show-sdk-path)"
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
sources=(Tidepad/Models/*.swift Tidepad/Documents/*.swift Tidepad/Editor/*.swift Tidepad/Syntax/*.swift Tidepad/Utilities/*.swift Tidepad/Search/SearchQuery.swift Tidepad/Search/SearchEngine.swift Tidepad/Search/SearchResultBuilder.swift Tidepad/Search/FindInFilesService.swift Tests/EditorPerformance.swift)
xcrun swiftc "${flags[@]}" -Onone "${sources[@]}" -o build/EditorPerformance-Debug
/usr/bin/time -l build/EditorPerformance-Debug > build/editor-debug-performance.log 2> build/editor-debug-memory.log
xcrun swiftc "${flags[@]}" -O "${sources[@]}" -o build/EditorPerformance-Release
/usr/bin/time -l build/EditorPerformance-Release > build/editor-release-performance.log 2> build/editor-release-memory.log
