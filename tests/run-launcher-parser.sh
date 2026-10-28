#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Compile the production parser with the rest of Mochi.swift, omitting only the
# app.run() bootstrap. The test executable never starts the Eden app.
sed '/^let app = NSApplication.shared/,$d' "$repo/Sources/Mochi.swift" > "$scratch/LauncherSource.swift"
sdk="${KATESCAPE_TEST_SDK:-$(xcrun --show-sdk-path)}"
swiftc -sdk "$sdk" -module-cache-path "$scratch/module-cache" \
    "$scratch/LauncherSource.swift" "$repo/tests/main.swift" -o "$scratch/launcher-tests"
"$scratch/launcher-tests"
