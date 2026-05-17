#!/usr/bin/env bash
#
# Build a signed Release .dmg of WhisperCaption.
#
# Usage:
#   ./scripts/build-release.sh <version>
#
# Example:
#   ./scripts/build-release.sh 1.0.0
#
# Output:
#   build/WhisperCaption-<version>.dmg
#
# The script:
#   1. archives a Release build
#   2. exports it via `development` distribution method
#   3. prints the codesign Authority chain so you can audit it
#   4. packages the .app into a compressed .dmg
#
# Signing identity is whatever DEVELOPMENT_TEAM resolves to in
# WhisperCaption/Local.xcconfig — that file is gitignored and machine-local.

set -euo pipefail

# ---- Args ----
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>   e.g. $0 1.0.0" >&2
  exit 2
fi
VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "ERROR: version must be SemVer (X.Y.Z or X.Y.Z-suffix). Got: $VERSION" >&2
  exit 2
fi

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="WhisperCaption"
PROJECT="$ROOT/WhisperCaption/WhisperCaption.xcodeproj"
CONFIG="Release"

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/$SCHEME.app"
DMG_PATH="$BUILD_DIR/WhisperCaption-$VERSION.dmg"

mkdir -p "$BUILD_DIR"

# ---- Read DEVELOPMENT_TEAM from Local.xcconfig ----
LOCAL_XCCONFIG="$ROOT/WhisperCaption/Local.xcconfig"
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  echo "ERROR: $LOCAL_XCCONFIG not found. Copy Local.xcconfig.template and fill in your DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM_ID="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$LOCAL_XCCONFIG" \
           | head -n 1 | awk -F'=' '{print $2}' | tr -d '[:space:]')"
if [[ -z "${TEAM_ID:-}" ]]; then
  echo "ERROR: DEVELOPMENT_TEAM is empty in $LOCAL_XCCONFIG." >&2
  echo "       Ad-hoc signed builds are not safe to distribute — fill in your team ID and retry." >&2
  exit 1
fi

echo "==> Version:           $VERSION"
echo "==> DEVELOPMENT_TEAM:  $TEAM_ID"
echo "==> Project:           $PROJECT"
echo "==> Output:            $DMG_PATH"
echo

# ---- Clean previous outputs ----
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"

# ---- 1. Archive ----
echo "==> [1/5] Archiving ($CONFIG)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  | grep -E '(error|warning|FAILED|SUCCEED|\.swift:[0-9]+:[0-9]+:)' || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "ERROR: archive failed — no .xcarchive at $ARCHIVE_PATH" >&2
  exit 1
fi

# ---- 2. Generate ExportOptions.plist (not committed — lives in build/) ----
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
EOF

# ---- 3. Export ----
echo
echo "==> [2/5] Exporting signed .app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: export failed — no .app at $APP_PATH" >&2
  exit 1
fi

# ---- 4. Verify codesign Authority — sanity audit ----
echo
echo "==> [3/5] Verifying codesign Authority..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "------ codesign -dvvv (anyone can run this on the published .dmg) ------"
codesign -dvvv "$APP_PATH" 2>&1 \
  | grep -E '^(Identifier|Authority|TeamIdentifier)'
echo "------------------------------------------------------------------------"
echo
echo "Review the Authority lines above. They must show the brand identity"
echo "(albond.dev@proton.me) and NOT any personal Apple ID."
echo

# ---- 5. Generate themed DMG background (graceful fallback if Pillow missing) ----
echo "==> [4/5] Generating themed installer background..."
BG_PNG="$BUILD_DIR/dmg-background.png"
FANCY_DMG=1
if ! python3 "$SCRIPT_DIR/build-dmg-background.py" "$BG_PNG"; then
  echo "    Background generator failed — falling back to plain DMG (no custom layout)."
  FANCY_DMG=0
fi

# ---- 6. Package .dmg ----
echo
echo "==> [5/5] Packaging $DMG_PATH..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_TEMP="$BUILD_DIR/WhisperCaption-temp.dmg"
DMG_VOLNAME="WhisperCaption"
rm -rf "$DMG_STAGING" "$DMG_TEMP"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
# First-launch guide — explains the Gatekeeper unlock and how to verify the
# binary signature. The user is meant to read this before double-clicking
# the .app.
cp "$ROOT/Docs/dmg-readme.txt" "$DMG_STAGING/Read me first.txt"

# Detach any leftover mount with the same volume name from a previous failed run.
if [[ -d "/Volumes/$DMG_VOLNAME" ]]; then
  hdiutil detach "/Volumes/$DMG_VOLNAME" -force >/dev/null 2>&1 || true
fi

if [[ "$FANCY_DMG" == "1" ]]; then
  # Embed the background image inside a hidden folder on the volume.
  mkdir "$DMG_STAGING/.background"
  cp "$BG_PNG" "$DMG_STAGING/.background/background.png"

  # 1. Create writable DMG large enough to fit .app + background + .DS_Store.
  hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$DMG_STAGING" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov \
    "$DMG_TEMP" >/dev/null

  # 2. Mount the writable DMG and capture its device node for later detach.
  DEVICE=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" \
           | grep -E '^/dev/' | head -n 1 | awk '{print $1}')
  if [[ -z "${DEVICE:-}" ]]; then
    echo "ERROR: failed to mount temporary DMG." >&2
    exit 1
  fi
  sleep 2

  # 3. Configure the Finder window. Window is 600×400 in 1× points (matches
  #    build-dmg-background.py canvas of 1200×800 at 2×). Order matters:
  #    bounds/toolbar before view options; finish with update + delay +
  #    close so Finder persists the state into .DS_Store.
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DMG_VOLNAME"
    open
    delay 1
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {400, 100, 1000, 500}
    end tell
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 88
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Read me first.txt" of container window to {300, 75}
    set position of item "WhisperCaption.app" of container window to {180, 205}
    set position of item "Applications" of container window to {420, 205}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

  # 4. Flush filesystem and detach cleanly.
  sync
  hdiutil detach "$DEVICE" >/dev/null

  # 5. Convert the writable temp DMG into a compressed read-only final DMG.
  hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null
  rm -f "$DMG_TEMP"
else
  # Plain fallback — no background, no icon layout. Still functional.
  hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
fi

rm -rf "$DMG_STAGING"

# ---- Done ----
DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

echo
echo "==> Done."
echo "    File:    $DMG_PATH"
echo "    Size:    $DMG_SIZE"
echo "    SHA-256: $DMG_SHA"
echo
echo "Upload to the matching GitHub Release:"
echo "    gh release upload v$VERSION '$DMG_PATH'"
echo "    gh release edit v$VERSION --draft=false"
