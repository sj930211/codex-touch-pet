#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$PROJECT_ROOT/.build/app/Codex Touch Pet.app"
PACKAGE_DIR="$PROJECT_ROOT/.build/package"
PACKAGE_APP="$PACKAGE_DIR/Codex Touch Pet.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "missing app bundle: $SOURCE_APP" >&2
    exit 1
fi

mkdir -p "$PACKAGE_DIR"
ditto "$SOURCE_APP" "$PACKAGE_APP"
mkdir -p "$PACKAGE_APP/Contents/Resources"
cp "$PROJECT_ROOT/README.md" "$PACKAGE_APP/Contents/Resources/README.md"
cp "$PROJECT_ROOT/NOTICE.txt" "$PACKAGE_APP/Contents/Resources/NOTICE.txt"

codesign --force --sign - "$PACKAGE_APP"
codesign --verify --deep --strict "$PACKAGE_APP"

echo "Packaged: $PACKAGE_APP"
echo "Executable: $PACKAGE_APP/Contents/MacOS/CodexTouchPet"
shasum -a 256 "$PACKAGE_APP/Contents/MacOS/CodexTouchPet"
