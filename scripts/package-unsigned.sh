#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
DERIVED_DATA_PATH="${FLOW_READER_DERIVED_DATA:-build/device}"
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA_PATH" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/flow-reader.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
ditto "$DERIVED_DATA_PATH/Build/Products/Release-iphoneos/FlowReader.app" "$STAGING/Payload/FlowReader.app"
test ! -e "$STAGING/Payload/FlowReader.app/embedded.mobileprovision"
rm -rf "$STAGING/Payload/FlowReader.app/_CodeSignature"
# Strip debug symbols from the staged binary so local build paths are not distributed.
APP_EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$STAGING/Payload/FlowReader.app/Info.plist")
xcrun strip -S "$STAGING/Payload/FlowReader.app/$APP_EXECUTABLE"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGING/Payload/FlowReader.app/Info.plist")
IPA_NAME="FlowReader-${APP_VERSION}-unsigned.ipa"
ditto -c -k --norsrc --keepParent "$STAGING/Payload" "dist/$IPA_NAME"
(cd dist && shasum -a 256 "$IPA_NAME" > SHA256SUMS.txt)
echo 'Unsigned IPA ready in dist/'
