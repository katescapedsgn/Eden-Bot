#!/bin/bash
# Build Eden locally; install only when explicitly called with --install.
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
BUNDLE="$BUILD/Eden.app"
APPS="$HOME/Applications"
TARGET="$APPS/Eden.app"
IDENTITY="Mochi Local Signing"
BUNDLE_ID="io.github.jessawolfe.mochi"
ICON_NAME="Eden.icns"
ICON_SOURCE="$REPO/assets/branding/Eden.icns"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

die() { echo "Eden: $*" >&2; exit 1; }
plist_value() { "$PLIST_BUDDY" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

sprite_paths() {
  local spec folder prefix count number
  for spec in idle:idle:4 blink:blink:4 sleeping:sleep:3 thinking:thinking:4 happy:happy:4 wave:wave:1 petting:pet:2 confused:confused:1; do
    IFS=: read -r folder prefix count <<< "$spec"
    for ((number=1; number<=count; number++)); do
      printf '%s/%s_%02d.png\n' "$folder" "$prefix" "$number"
    done
  done
}

validate_bundle() {
  local app="$1"
  local icon_file
  [[ -d "$app/Contents/MacOS" && -d "$app/Contents/Resources" ]] || return 1
  [[ -x "$app/Contents/MacOS/Eden" ]] || return 1
  plutil -lint "$app/Contents/Info.plist" >/dev/null || return 1
  [[ "$(plist_value "$app" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || return 1
  [[ "$(plist_value "$app" CFBundleName)" == "Eden" ]] || return 1
  [[ "$(plist_value "$app" CFBundleDisplayName)" == "Eden" ]] || return 1
  [[ "$(plist_value "$app" CFBundleExecutable)" == "Eden" ]] || return 1
  case "$(plist_value "$app" CFBundleIconFile)" in
    Eden|Eden.icns) icon_file="Eden.icns" ;;
    Katescape|Katescape.icns) icon_file="Katescape.icns" ;;
    Mochi|Mochi.icns) icon_file="Mochi.icns" ;; # Existing local builds remain replaceable.
    *) return 1 ;;
  esac
  [[ -s "$app/Contents/Resources/$icon_file" ]] || return 1
  [[ "$(plist_value "$app" KatescapeLocalBuild)" == "true" ]] || return 1
}

validate_cat_sprites() {
  local app="$1" relative source bundled
  while IFS= read -r relative; do
    source="$REPO/assets/sprites/eden/$relative"
    bundled="$app/Contents/Resources/PetSprites/Eden/$relative"
    [[ -s "$source" && -s "$bundled" ]] || return 1
    cmp -s "$source" "$bundled" || return 1
  done < <(sprite_paths)
  [[ "$(find "$app/Contents/Resources/PetSprites/Eden" -type f -name '*.png' | wc -l | tr -d ' ')" == 23 ]]
}

command -v swiftc >/dev/null || die "swiftc is unavailable. Install Apple's Command Line Tools separately."
[[ -f "$REPO/Sources/Mochi.swift" ]] || die "Swift source is missing."
SDK="$(xcrun --show-sdk-path)" || die "Could not locate the active macOS SDK."
[[ -f "$ICON_SOURCE" && -s "$ICON_SOURCE" ]] || die "Eden icon is missing or empty: $ICON_SOURCE"
sips -g format "$ICON_SOURCE" 2>/dev/null | grep -q 'format: icns' || die "Icon is not a valid .icns file: $ICON_SOURCE"
[[ "$(find "$REPO/assets/sprites/eden" -type f -name '*.png' | wc -l | tr -d ' ')" == 23 ]] || die "Expected exactly 23 Eden animation sprites."
while IFS= read -r RELATIVE; do
  SPRITE="$REPO/assets/sprites/eden/$RELATIVE"
  [[ -s "$SPRITE" ]] || die "Missing pet sprite: $SPRITE"
  DETAILS="$(sips -g pixelWidth -g pixelHeight -g format -g hasAlpha "$SPRITE" 2>/dev/null)" || die "Unreadable pet sprite: $SPRITE"
  WIDTH=288; HEIGHT=288
  case "$RELATIVE" in
    sleeping/*) HEIGHT=256 ;;
    happy/*) WIDTH=320; HEIGHT=320 ;;
  esac
  [[ "$DETAILS" == *"pixelWidth: $WIDTH"* && "$DETAILS" == *"pixelHeight: $HEIGHT"* && "$DETAILS" == *"format: png"* && "$DETAILS" == *"hasAlpha: yes"* ]] || die "Pet sprite must be a transparent ${WIDTH}×${HEIGHT} PNG: $SPRITE"
done < <(sprite_paths)
mkdir -p "$BUILD"
STAGE="$(mktemp -d "$BUILD/.katescape-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Eden.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if ! swiftc -O -sdk "$SDK" -module-cache-path "$STAGE/module-cache" "$REPO/Sources/Mochi.swift" -o "$APP/Contents/MacOS/Eden" 2> "$STAGE/errors.txt"; then
  if grep -q "redefinition of module" "$STAGE/errors.txt"; then
    : > "$STAGE/empty.modulemap"
    printf '{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "external-contents": "%s/empty.modulemap" } ] }' "$STAGE" > "$STAGE/overlay.yaml"
    swiftc -O -sdk "$SDK" -module-cache-path "$STAGE/module-cache" -vfsoverlay "$STAGE/overlay.yaml" "$REPO/Sources/Mochi.swift" -o "$APP/Contents/MacOS/Eden" || die "Swift compilation failed with the module-map workaround."
  else
    cat "$STAGE/errors.txt" >&2
    die "Swift compilation failed."
  fi
fi

cp "$ICON_SOURCE" "$APP/Contents/Resources/$ICON_NAME"
while IFS= read -r RELATIVE; do
  DESTINATION="$APP/Contents/Resources/PetSprites/Eden/$RELATIVE"
  mkdir -p "$(dirname "$DESTINATION")"
  cp "$REPO/assets/sprites/eden/$RELATIVE" "$DESTINATION"
done < <(sprite_paths)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Eden</string>
  <key>CFBundleDisplayName</key><string>Eden</string>
  <key>CFBundleIdentifier</key><string>io.github.jessawolfe.mochi</string>
  <key>CFBundleExecutable</key><string>Eden</string>
  <key>CFBundleIconFile</key><string>Eden.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Eden sends your messages to the selected CLI in Terminal and, if enabled, reads unread counts from social tabs open in Chrome.</string>
  <key>KatescapeLocalBuild</key><true/>
</dict></plist>
PLIST
validate_bundle "$APP" || die "The built app bundle failed structural validation."
validate_cat_sprites "$APP" || die "The built app bundle is missing pet sprites."
[[ "$(plist_value "$APP" CFBundleIconFile)" == "$ICON_NAME" ]] || die "Built app icon reference is incorrect."
cmp -s "$ICON_SOURCE" "$APP/Contents/Resources/$ICON_NAME" || die "Built app icon differs from assets/branding/Eden.icns."

SIGNED=false
if [[ "$AD_HOC" == true ]]; then
  # Copied PNGs may carry FinderInfo or resource-fork metadata that codesign rejects.
  # Clean only the temporary app bundle; leave source artwork and earlier builds intact.
  xattr -cr "$APP" || die "Could not remove extended attributes from the staged app."
  codesign --force --sign - "$APP" || die "Ad hoc signing failed."
  codesign --verify --deep --strict "$APP" || die "Ad hoc signature verification failed."
  SIGNED=true
elif security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  xattr -cr "$APP" || die "Could not remove extended attributes from the staged app."
  codesign --force --sign "$IDENTITY" "$APP" || die "Signing failed for '$IDENTITY'. No ad hoc signature was used."
  codesign --verify --deep --strict "$APP" || die "Code signature verification failed."
  SIGNED=true
fi

if [[ -e "$BUNDLE" || -L "$BUNDLE" ]]; then
  [[ ! -L "$BUNDLE" && -d "$BUNDLE" ]] || die "Existing build/Eden.app is not a regular app directory."
  validate_bundle "$BUNDLE" || die "Existing build/Eden.app is not an Eden local build; left untouched."
  OLD_BUILD="$BUILD/Eden.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$BUNDLE" "$OLD_BUILD" || die "Could not back up the previous build."
  echo "Previous build backed up to: $OLD_BUILD"
fi
mv "$APP" "$BUNDLE" || die "Could not place the built app in build/."
validate_bundle "$BUNDLE" || die "Final build bundle failed validation."
validate_cat_sprites "$BUNDLE" || die "Final build is missing pet sprites."
[[ "$(plist_value "$BUNDLE" CFBundleIconFile)" == "$ICON_NAME" ]] || die "Final build icon reference is incorrect."
cmp -s "$ICON_SOURCE" "$BUNDLE/Contents/Resources/$ICON_NAME" || die "Final build icon differs from assets/branding/Eden.icns."
echo "Built and validated: $BUNDLE"
for OLD_APP in "$APPS/Katescape.app" "/Applications/Katescape.app"; do
  if [[ -e "$OLD_APP" || -L "$OLD_APP" ]]; then
    echo "Previous Katescape.app detected at $OLD_APP; it was left untouched." >&2
  fi
done

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
check_not_running() {
  local name="$1" status=0
  pgrep -x "$name" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) die "Quit the running $name app before installing Eden." ;;
    1) ;;
    *) die "Could not verify whether $name is running. Installation stopped safely." ;;
  esac
}
check_not_running Eden
check_not_running Katescape
for OLD_APP in "$APPS/Katescape.app" "/Applications/Katescape.app"; do
  if [[ -e "$OLD_APP" || -L "$OLD_APP" ]]; then
    die "Previous Katescape.app is still at $OLD_APP. Move it to your own backup location before installing Eden; it was left untouched."
  fi
done
mkdir -p "$APPS" || die "Could not create ~/Applications."
INCOMING="$(mktemp -d "$APPS/.katescape-install.XXXXXX")"
trap 'rm -rf "$INCOMING"; rm -rf "$STAGE"' EXIT
ditto "$BUNDLE" "$INCOMING/Eden.app" || die "Could not stage the app in ~/Applications."
validate_bundle "$INCOMING/Eden.app" || die "Staged app failed validation."
validate_cat_sprites "$INCOMING/Eden.app" || die "Staged app is missing pet sprites."
[[ "$(plist_value "$INCOMING/Eden.app" CFBundleIconFile)" == "$ICON_NAME" ]] || die "Staged app icon reference is incorrect."
cmp -s "$ICON_SOURCE" "$INCOMING/Eden.app/Contents/Resources/$ICON_NAME" || die "Staged app icon differs from assets/branding/Eden.icns."
codesign --verify --deep --strict "$INCOMING/Eden.app" || die "Staged app signature is invalid."

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  [[ ! -L "$TARGET" && -d "$TARGET" ]] || die "Existing target is not a regular app directory; left untouched."
  validate_bundle "$TARGET" || die "Existing target is not the expected Eden local app; left untouched."
  [[ -t 0 ]] || die "Replacing an existing app requires an interactive confirmation."
  printf 'Replace the verified Eden local app? Type Eden.app to confirm: '
  read -r CONFIRM
  [[ "$CONFIRM" == "Eden.app" ]] || die "Confirmation did not match; existing app left untouched."
  BACKUP="$APPS/Eden.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$TARGET" "$BACKUP" || die "Could not back up the existing app."
  if ! mv "$INCOMING/Eden.app" "$TARGET"; then
    mv "$BACKUP" "$TARGET" || echo "Restore failed; previous app remains at $BACKUP" >&2
    die "Installation failed; the previous app was restored when possible."
  fi
  echo "Previous app backed up to: $BACKUP"
else
  mv "$INCOMING/Eden.app" "$TARGET" || die "Could not install Eden.app."
fi
echo "Installed: $TARGET"
echo "Eden was not launched."
