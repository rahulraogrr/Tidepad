#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
flags=(-O -g -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
editor=(Tidepad/Models/*.swift Tidepad/Documents/*.swift Tidepad/Editor/*.swift Tidepad/Syntax/*.swift Tidepad/Utilities/*.swift)
search=(Tidepad/Search/SearchQuery.swift Tidepad/Search/SearchEngine.swift Tidepad/Search/SearchResultBuilder.swift Tidepad/Search/FindInFilesService.swift)
xcrun swiftc "${flags[@]}" "${editor[@]}" "${search[@]}" Tests/EditorPerformance.swift -o build/EditorAfter
build/EditorAfter > build/editor-after-matrix.log
xcrun swiftc "${flags[@]}" "${editor[@]}" Tests/MemoryPerformance.swift -o build/MemoryPerformance
for size in 1000000 10000000 50000000; do build/MemoryPerformance "$size" > "build/memory-$size.log"; done
xcrun swiftc "${flags[@]}" Tidepad/Models/EditorDocument.swift Tidepad/Editor/LineIndex.swift Tidepad/Syntax/SyntaxLanguage.swift Tests/NativeCoreBench.swift -o build/NativeCoreBench
for size in 1000000 10000000 50000000; do
    for mode in io tk1 tk2 tk1noncontiguous; do
        build/NativeCoreBench "$mode" "$size" > "build/native-$mode-$size.log" 2>&1
    done
done
xcrun swiftc "${flags[@]}" Tidepad/Models/EditorDocument.swift Tidepad/Storage/FileStamp.swift Tidepad/Documents/TextFileService.swift Tidepad/Editor/LineIndex.swift Tidepad/Syntax/SyntaxLanguage.swift Tidepad/Syntax/LineLexer.swift Tidepad/Syntax/IncrementalSyntaxEngine.swift Tests/SyntaxPerformance.swift -o build/SyntaxPerformance
build/SyntaxPerformance > build/syntax-performance.log
bash Tests/run-search-checks.sh
