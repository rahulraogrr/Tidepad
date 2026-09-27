#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
xcrun swiftc "${flags[@]}" Tidepad/Models/EditorDocument.swift Tidepad/Documents/TextFileService.swift Tidepad/Editor/LineIndex.swift Tidepad/Syntax/SyntaxLanguage.swift Tests/CoreChecks.swift -o build/CoreChecks
build/CoreChecks
xcrun swiftc "${flags[@]}" Tidepad/Syntax/SyntaxLanguage.swift Tidepad/Syntax/LineLexer.swift Tidepad/Syntax/IncrementalSyntaxEngine.swift Tidepad/Editor/BracketMatcher.swift Tests/SyntaxChecks.swift -o build/SyntaxChecks
build/SyntaxChecks
xcrun swiftc "${flags[@]}" Tidepad/Editor/TextCommands.swift Tidepad/Editor/SQLFormatter.swift Tests/TextCommandChecks.swift -o build/TextCommandChecks
build/TextCommandChecks
xcrun swiftc -O "${flags[@]}" Tidepad/Storage/MappedUTF8Text.swift Tidepad/Storage/PieceTable.swift Tidepad/Storage/PieceTableString.swift Tests/StorageChecks.swift -o build/StorageChecks
build/StorageChecks
xcrun swiftc "${flags[@]}" Tidepad/Models/*.swift Tidepad/Documents/*.swift Tidepad/Editor/*.swift Tidepad/Syntax/*.swift Tidepad/Utilities/*.swift Tests/EditorChecks.swift -o build/EditorChecks
build/EditorChecks
