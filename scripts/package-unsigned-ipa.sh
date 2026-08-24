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

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command xcodegen
require_command xcodebuild
require_command zip

echo "Generating $PROJECT_PATH from project.yml"
xcodegen generate --spec "$ROOT/project.yml" --project-root "$ROOT" --quiet
test -d "$PROJECT_PATH"

rm -rf "$PACKAGE_ROOT" "$OUTPUT"
mkdir -p "$PAYLOAD_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
test -d "$APP_PATH"

MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist")"
if [[ "$MINIMUM_OS" != "14.0" ]]; then
  echo "Expected MinimumOSVersion 14.0, got $MINIMUM_OS" >&2
  exit 1
fi

test -f "$APP_PATH/PrivacyInfo.xcprivacy"
plutil -lint "$APP_PATH/PrivacyInfo.xcprivacy"
test -f "$APP_PATH/LICENSE"
grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$APP_PATH/LICENSE"
test -f "$APP_PATH/SwiftProtobuf-Apache-2.0.txt"
grep -Fq 'Apache License' "$APP_PATH/SwiftProtobuf-Apache-2.0.txt"

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
  "gitCommit": "$GIT_SHA",
  "minimumOS": "14.0",
  "sdk": "$SDK_VERSION",
  "xcode": "$XCODE_VERSION",
  "signed": false
}
EOF

echo "$OUTPUT"
