#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${TIEBAX_BUILD_DIR:-$ROOT/build}"
DERIVED_DATA="${TIEBAX_DERIVED_DATA:-${RUNNER_TEMP:-/tmp}/TieBaXDerivedData}"
PACKAGE_ROOT="$BUILD_DIR/unsigned-ipa"
ARCHIVE_PATH="$PACKAGE_ROOT/TieBaX.xcarchive"
PAYLOAD_DIR="$PACKAGE_ROOT/Payload"
PROJECT_PATH="$ROOT/TieBaX.xcodeproj"
APP_NAME="TieBa-X.app"
SCHEME="TieBaX"
VERSION="${TIEBAX_VERSION:-0.1.0}"
OUTPUT="$BUILD_DIR/TieBa-X-${VERSION}-unsigned.ipa"
RESULT_BUNDLE="$BUILD_DIR/TieBaX-archive.xcresult"
APP_VERSION="${VERSION%%-*}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  APP_VERSION="0.1.0"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command xcodegen
require_command xcodebuild
require_command zip

fail() {
  echo "::error::$*" >&2
  exit 1
}

require_path() {
  local path="$1"
  [[ -e "$path" ]] && return 0
  echo "::error::Missing required path: $path" >&2
  if [[ -d "$PACKAGE_ROOT" ]]; then
    echo "Archive/package contents:" >&2
    find "$PACKAGE_ROOT" -maxdepth 4 -print >&2
  fi
  exit 1
}

require_path "$ROOT/PrivacyInfo.xcprivacy"

echo "Generating $PROJECT_PATH from project.yml"
xcodegen generate --spec "$ROOT/project.yml" --project-root "$ROOT" --quiet
test -d "$PROJECT_PATH"
grep -Fq 'path = Assets.xcassets' "$PROJECT_PATH/project.pbxproj" \
  || fail "Generated Xcode project does not reference the root Assets.xcassets resource"
echo "Generated asset catalog references:"
grep -n -C 2 'Assets.xcassets' "$PROJECT_PATH/project.pbxproj" || true

rm -rf "$PACKAGE_ROOT" "$OUTPUT" "$RESULT_BUNDLE"
mkdir -p "$PAYLOAD_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$APP_VERSION" \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
require_path "$APP_PATH"
require_path "$APP_PATH/Info.plist"
require_path "$APP_PATH/Assets.car"

if ! ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP_PATH/Info.plist" 2>/dev/null)"; then
  fail "Archive app Info.plist is missing CFBundleIconName"
fi
if [[ "$ICON_NAME" != "AppIcon" ]]; then
  fail "Expected CFBundleIconName AppIcon, got $ICON_NAME"
fi

if ! MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist" 2>/dev/null)"; then
  fail "Archive app Info.plist is missing MinimumOSVersion"
fi
if [[ "$MINIMUM_OS" != "14.0" ]]; then
  fail "Expected MinimumOSVersion 14.0, got $MINIMUM_OS"
fi

require_path "$APP_PATH/PrivacyInfo.xcprivacy"
plutil -lint "$APP_PATH/PrivacyInfo.xcprivacy" >/dev/null \
  || fail "PrivacyInfo.xcprivacy is not a valid plist"
require_path "$APP_PATH/LICENSE"
grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$APP_PATH/LICENSE" \
  || fail "Bundled LICENSE does not contain the GPL notice"
require_path "$APP_PATH/SwiftProtobuf-Apache-2.0.txt"
grep -Fq 'Apache License' "$APP_PATH/SwiftProtobuf-Apache-2.0.txt" \
  || fail "Bundled SwiftProtobuf license notice is missing"

/usr/bin/ditto "$APP_PATH" "$PAYLOAD_DIR/$APP_NAME"
rm -rf "$PAYLOAD_DIR/$APP_NAME/_CodeSignature"
rm -f "$PAYLOAD_DIR/$APP_NAME/embedded.mobileprovision"

(cd "$PACKAGE_ROOT" && /usr/bin/zip -qry "$OUTPUT" Payload)

SHA_FILE="$OUTPUT.sha256"
shasum -a 256 "$OUTPUT" > "$SHA_FILE"

BUILD_INFO="$BUILD_DIR/TieBa-X-${VERSION}-build-info.json"
GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || printf 'unknown')"
cat > "$BUILD_INFO" <<EOF
{
  "product": "TieBa-X",
  "version": "$VERSION",
  "appVersion": "$APP_VERSION",
  "gitCommit": "$GIT_SHA",
  "minimumOS": "14.0",
  "sdk": "$SDK_VERSION",
  "xcode": "$XCODE_VERSION",
  "signed": false
}
EOF

echo "$OUTPUT"
