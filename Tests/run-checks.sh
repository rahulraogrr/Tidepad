#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sdk="$(xcrun --show-sdk-path)"
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/TestModuleCache)
xcrun swiftc "${flags[@]}" Tidepad/Models/EditorDocument.swift Tidepad/Models/TextEncodingChoice.swift Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tidepad/Documents/TextFileService.swift Tidepad/Editor/LineIndex.swift Tidepad/Syntax/SyntaxLanguage.swift Tests/CoreChecks.swift -o build/CoreChecks
build/CoreChecks
xcrun swiftc "${flags[@]}" Tidepad/Models/EditorDocument.swift Tidepad/Models/TextEncodingChoice.swift Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tidepad/Documents/TextFileService.swift Tidepad/Editor/LineIndex.swift Tidepad/Syntax/SyntaxLanguage.swift Tidepad/Syntax/LineLexer.swift Tidepad/Syntax/IncrementalSyntaxEngine.swift Tidepad/Syntax/LargeSyntaxEngine.swift Tidepad/Editor/BracketMatcher.swift Tests/SyntaxChecks.swift -o build/SyntaxChecks
build/SyntaxChecks
xcrun swiftc "${flags[@]}" Tidepad/Editor/TextCommands.swift Tidepad/Editor/SQLFormatter.swift Tests/TextCommandChecks.swift -o build/TextCommandChecks
build/TextCommandChecks
xcrun swiftc -O "${flags[@]}" Tidepad/Terminal/TerminalScreen.swift Tidepad/Terminal/TerminalAccessibility.swift Tests/TerminalChecks.swift -o build/TerminalChecks
build/TerminalChecks
xcrun swiftc "${flags[@]}" Tidepad/Project/FolderListing.swift Tests/FolderChecks.swift -o build/FolderChecks
build/FolderChecks
xcrun swiftc -O "${flags[@]}" Tidepad/Storage/MappedUTF8Text.swift Tidepad/Storage/PieceTable.swift Tidepad/Storage/PieceTableString.swift Tests/StorageChecks.swift -o build/StorageChecks
build/StorageChecks
xcrun swiftc -O "${flags[@]}" Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tests/LargeFileChecks.swift -o build/LargeFileChecks
build/LargeFileChecks
xcrun swiftc -O "${flags[@]}" Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tidepad/Search/SearchQuery.swift Tidepad/Search/SearchEngine.swift Tidepad/Search/LargeTextSearch.swift Tests/LargeSearchChecks.swift -o build/LargeSearchChecks
build/LargeSearchChecks
xcrun swiftc "${flags[@]}" Tidepad/AI/AIPrompts.swift Tests/AIChecks.swift -o build/AIChecks
build/AIChecks
xcrun swiftc "${flags[@]}" Tidepad/Models/*.swift Tidepad/Documents/*.swift Tidepad/Editor/*.swift Tidepad/Syntax/*.swift Tidepad/Utilities/*.swift Tidepad/Project/*.swift Tidepad/Terminal/*.swift Tidepad/Session/*.swift Tidepad/Storage/LargeTextFile.swift Tidepad/Storage/LargeTextBuffer.swift Tidepad/Search/SearchQuery.swift Tidepad/Search/SearchEngine.swift Tidepad/Search/LargeTextSearch.swift Tests/EditorChecks.swift -o build/EditorChecks
build/EditorChecks
