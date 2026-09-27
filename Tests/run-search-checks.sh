#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
sources=(Tidepad/Search/SearchQuery.swift Tidepad/Search/SearchEngine.swift Tidepad/Search/SearchResultBuilder.swift Tidepad/Search/FindInFilesService.swift Tests/SearchChecks.swift)
xcrun swiftc "${flags[@]}" -D DEBUG -Onone "${sources[@]}" -o build/SearchChecks-Debug
build/SearchChecks-Debug > build/search-debug-benchmarks.log
xcrun swiftc "${flags[@]}" -O "${sources[@]}" -o build/SearchChecks-Release
build/SearchChecks-Release > build/search-release-benchmarks.log
