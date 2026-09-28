#!/bin/bash
# Rebuilds the search index of Tidepad Help (Tidepad/Tidepad.help) after its pages change, so the Help
# menu's search and the Keyboard Shortcuts item find them. hiutil comes with macOS. Commit the results.
set -euo pipefail
cd "$(dirname "$0")/../Tidepad/Tidepad.help/Contents/Resources/en.lproj"
hiutil -I corespotlight -Caf Tidepad.cshelpindex -vv .
hiutil -I lsm -Caf Tidepad.helpindex -vv .
echo "Help index rebuilt."
