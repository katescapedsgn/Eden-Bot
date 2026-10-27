#!/bin/bash
# Build Katescape locally; install only when explicitly called with --install.
set -euo pipefail

usage() {
  echo "Usage: ./scripts/install-local.sh [--build-only|--install] [--ad-hoc]" >&2
  exit 2
}

MODE="--build-only"
MODE_SEEN=false
AD_HOC=false
for ARG in "$@"; do
  case "$ARG" in
    --build-only|--install)
      [[ "$MODE_SEEN" == false ]] || usage
      MODE="$ARG"; MODE_SEEN=true ;;
    --ad-hoc)
      [[ "$AD_HOC" == false ]] || usage
      AD_HOC=true ;;
    *) usage ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="$REPO/build"
BUNDLE="$BUILD/Katescape.app"
APPS="$HOME/Applications"
TARGET="$APPS/Katescape.app"
IDENTITY="Mochi Local Signing"
BUNDLE_ID="io.github.jessawolfe.mochi"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

die() { echo "Katescape: $*" >&2; exit 1; }
plist_value() { "$PLIST_BUDDY" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

validate_bundle() {
  local app="$1"
  [[ -d "$app/Contents/MacOS" && -d "$app/Contents/Resources" ]] || return 1
  [[ -x "$app/Contents/MacOS/Katescape" && -s "$app/Contents/Resources/Mochi.icns" ]] || return 1
  plutil -lint "$app/Contents/Info.plist" >/dev/null || return 1
  [[ "$(plist_value "$app" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || return 1
  [[ "$(plist_value "$app" CFBundleName)" == "Katescape" ]] || return 1
  [[ "$(plist_value "$app" CFBundleExecutable)" == "Katescape" ]] || return 1
  [[ "$(plist_value "$app" KatescapeLocalBuild)" == "true" ]] || return 1
}

command -v swiftc >/dev/null || die "swiftc is unavailable. Install Apple's Command Line Tools separately."
[[ -f "$REPO/Sources/Mochi.swift" && -f "$REPO/assets/Mochi.icns" ]] || die "Source or icon is missing."
mkdir -p "$BUILD"
STAGE="$(mktemp -d "$BUILD/.katescape-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Katescape.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if ! swiftc -O "$REPO/Sources/Mochi.swift" -o "$APP/Contents/MacOS/Katescape" 2> "$STAGE/errors.txt"; then
  if grep -q "redefinition of module" "$STAGE/errors.txt"; then
    : > "$STAGE/empty.modulemap"
    printf '{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "external-contents": "%s/empty.modulemap" } ] }' "$STAGE" > "$STAGE/overlay.yaml"
    swiftc -O -vfsoverlay "$STAGE/overlay.yaml" "$REPO/Sources/Mochi.swift" -o "$APP/Contents/MacOS/Katescape" || die "Swift compilation failed with the module-map workaround."
  else
    cat "$STAGE/errors.txt" >&2
    die "Swift compilation failed."
  fi
fi

cp "$REPO/assets/Mochi.icns" "$APP/Contents/Resources/Mochi.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Katescape</string>
  <key>CFBundleDisplayName</key><string>Katescape</string>
  <key>CFBundleIdentifier</key><string>io.github.jessawolfe.mochi</string>
  <key>CFBundleExecutable</key><string>Katescape</string>
  <key>CFBundleIconFile</key><string>Mochi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Katescape sends your messages to the selected CLI in Terminal and, if enabled, reads unread counts from social tabs open in Chrome.</string>
  <key>KatescapeLocalBuild</key><true/>
</dict></plist>
PLIST
validate_bundle "$APP" || die "The built app bundle failed structural validation."

SIGNED=false
if [[ "$AD_HOC" == true ]]; then
  codesign --force --sign - "$APP" || die "Ad hoc signing failed."
  codesign --verify --deep --strict "$APP" || die "Ad hoc signature verification failed."
  SIGNED=true
elif security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP" || die "Signing failed for '$IDENTITY'. No ad hoc signature was used."
  codesign --verify --deep --strict "$APP" || die "Code signature verification failed."
  SIGNED=true
fi

if [[ -e "$BUNDLE" || -L "$BUNDLE" ]]; then
  [[ ! -L "$BUNDLE" && -d "$BUNDLE" ]] || die "Existing build/Katescape.app is not a regular app directory."
  validate_bundle "$BUNDLE" || die "Existing build/Katescape.app is not a Katescape local build; left untouched."
  OLD_BUILD="$BUILD/Katescape.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$BUNDLE" "$OLD_BUILD" || die "Could not back up the previous build."
  echo "Previous build backed up to: $OLD_BUILD"
fi
mv "$APP" "$BUNDLE" || die "Could not place the built app in build/."
validate_bundle "$BUNDLE" || die "Final build bundle failed validation."
echo "Built and validated: $BUNDLE"

if [[ "$MODE" == "--build-only" ]]; then
  if [[ "$AD_HOC" == true ]]; then
    echo "Ad hoc signed build only. macOS may ask for Automation and Accessibility permission again after an update." >&2
  elif [[ "$SIGNED" == false ]]; then
    echo "Unsigned build only: '$IDENTITY' is not a valid signing identity. Installation will refuse it." >&2
  fi
  exit 0
fi

[[ "$SIGNED" == true ]] || die "Installation requires the existing '$IDENTITY' signing identity. The build was not installed."
codesign --verify --deep --strict "$BUNDLE" || die "Built app signature is invalid."
if [[ "$AD_HOC" == true ]]; then
  echo "Ad hoc signing can reset macOS Automation and Accessibility grants across rebuilds." >&2
  [[ -t 0 ]] || die "Ad hoc installation requires interactive confirmation."
  printf 'Type ADHOC to continue with an ad hoc signed installation: '
  read -r CONFIRM_AD_HOC
  [[ "$CONFIRM_AD_HOC" == "ADHOC" ]] || die "Ad hoc installation cancelled."
fi
if pgrep -x Katescape >/dev/null 2>&1; then die "Quit the running Katescape app before installing."; fi
mkdir -p "$APPS" || die "Could not create ~/Applications."
INCOMING="$(mktemp -d "$APPS/.katescape-install.XXXXXX")"
trap 'rm -rf "$INCOMING"; rm -rf "$STAGE"' EXIT
ditto "$BUNDLE" "$INCOMING/Katescape.app" || die "Could not stage the app in ~/Applications."
validate_bundle "$INCOMING/Katescape.app" || die "Staged app failed validation."
codesign --verify --deep --strict "$INCOMING/Katescape.app" || die "Staged app signature is invalid."

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  [[ ! -L "$TARGET" && -d "$TARGET" ]] || die "Existing target is not a regular app directory; left untouched."
  validate_bundle "$TARGET" || die "Existing target is not the expected Katescape test app; left untouched."
  [[ -t 0 ]] || die "Replacing an existing app requires an interactive confirmation."
  printf 'Replace the verified Katescape test app? Type Katescape.app to confirm: '
  read -r CONFIRM
  [[ "$CONFIRM" == "Katescape.app" ]] || die "Confirmation did not match; existing app left untouched."
  BACKUP="$APPS/Katescape.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$TARGET" "$BACKUP" || die "Could not back up the existing app."
  if ! mv "$INCOMING/Katescape.app" "$TARGET"; then
    mv "$BACKUP" "$TARGET" || echo "Restore failed; previous app remains at $BACKUP" >&2
    die "Installation failed; the previous app was restored when possible."
  fi
  echo "Previous app backed up to: $BACKUP"
else
  mv "$INCOMING/Katescape.app" "$TARGET" || die "Could not install Katescape.app."
fi
echo "Installed: $TARGET"
echo "Katescape was not launched."
