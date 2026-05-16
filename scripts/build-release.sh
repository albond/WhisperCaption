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
echo "==> [1/4] Archiving ($CONFIG)..."
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
echo "==> [2/4] Exporting signed .app..."
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
echo "==> [3/4] Verifying codesign Authority..."
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

# ---- 5. Package .dmg ----
echo "==> [4/4] Packaging $DMG_PATH..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "WhisperCaption" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

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
