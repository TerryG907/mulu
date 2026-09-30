#!/usr/bin/env bash
# Build Mulu.app from the SwiftPM executable target `MuluApp` (GUI_SPEC §8).
#
# Usage: scripts/package_app.sh [--version 0.1.0] [--skip-build] [--scratch-path DIR]
# Output: dist/Mulu.app and dist/Mulu-<version>-macos-arm64.zip (SHA-256 printed).
#
# The release build takes 1–3 minutes. Automated callers should run this script in the background and poll
# its log. The app is signed ad hoc (no Developer ID, no notarization; see GUI_SPEC §8.5).
set -euo pipefail

VERSION="0.1.0"
SKIP_BUILD=0
SCRATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --scratch-path) SCRATCH="${2:?--scratch-path needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "package_app: unknown option $1" >&2; exit 2 ;;
  esac
done
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "package_app: version must look like 0.1.0 (got '$VERSION')" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT_FLAGS=(-c release)
if [[ -n "$SCRATCH" ]]; then SWIFT_FLAGS+=(--scratch-path "$SCRATCH"); fi

# 1. Build.
if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> swift build ${SWIFT_FLAGS[*]} --product MuluApp"
  nice -n 15 swift build "${SWIFT_FLAGS[@]}" --product MuluApp
fi
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
EXE="$BIN/MuluApp"
RESOURCES="$BIN/mulu_MuluApp.bundle"
[[ -x "$EXE" ]] || { echo "package_app: $EXE not found (build first or drop --skip-build)" >&2; exit 1; }
[[ -d "$RESOURCES" ]] || { echo "package_app: $RESOURCES not found" >&2; exit 1; }

# 2–3. Bundle skeleton and executable (renamed from MuluApp to Mulu).
APP="$ROOT/dist/Mulu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/Mulu"

# 4. Resources: the SwiftPM resource bundle (so Bundle.module never traps) and the English
#    strings in the main bundle, where Text("…") and String(localized:) look them up.
cp -R "$RESOURCES" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
STRINGS_FOUND=0
while IFS= read -r -d '' file; do
  cp "$file" "$APP/Contents/Resources/en.lproj/"
  STRINGS_FOUND=1
done < <(find "$RESOURCES" -path '*/en.lproj/*' \( -name '*.strings' -o -name '*.stringsdict' \) -print0)
if [[ $STRINGS_FOUND -eq 0 ]]; then
  echo "package_app: no en.lproj strings in $RESOURCES; the English UI would be missing" >&2
  exit 1
fi
# App icon: drawn by scripts/make_icon.swift and committed; excluded from the SwiftPM target, so
# it is copied from the source tree.
ICON="$ROOT/Sources/MuluApp/Resources/AppIcon.icns"
[[ -f "$ICON" ]] || { echo "package_app: $ICON not found (run: swift scripts/make_icon.swift)" >&2; exit 1; }
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# 5. Info.plist (GUI_SPEC §8.3).
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.terryg907.mulu</string>
  <key>CFBundleName</key><string>Mulu</string>
  <key>CFBundleDisplayName</key><string>Mulu</string>
  <key>CFBundleExecutable</key><string>Mulu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 TerryG907. MIT License.</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# 6. Ad-hoc signature (no entitlements: no sandbox; Vision, PDFKit and file access need none).
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 7. Zip for distribution.
ZIP="$ROOT/dist/Mulu-${VERSION}-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 8. Summary.
echo
echo "App:     $APP ($(du -sh "$APP" | cut -f1))"
echo "Arch:    $(lipo -archs "$APP/Contents/MacOS/Mulu")"
echo "Icon:    Contents/Resources/AppIcon.icns ($(du -h "$APP/Contents/Resources/AppIcon.icns" | cut -f1))"
echo "Version: $VERSION (build $BUILD)"
echo "Zip:     $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
