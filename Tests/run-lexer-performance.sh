#!/bin/bash
# Measures the lexer, optimised (as shipped) and unoptimised (as in Debug builds):
#   Tests/run-lexer-performance.sh [megabytes, default 20]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
flags=(-sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
files=(Tidepad/Syntax/SyntaxLanguage.swift Tidepad/Syntax/LineLexer.swift Tidepad/Syntax/LargeSyntaxEngine.swift
       Tidepad/Storage/FileStamp.swift Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tests/LexerPerformance.swift)
echo "Release (-O):"
xcrun swiftc -O "${flags[@]}" "${files[@]}" -o build/LexerPerformance
build/LexerPerformance "${1:-20}"
echo "Debug (-Onone):"
xcrun swiftc -Onone "${flags[@]}" "${files[@]}" -o build/LexerPerformanceDebug
build/LexerPerformanceDebug "${1:-20}"
