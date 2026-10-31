#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/flow-reader.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
ditto build/device/Build/Products/Release-iphoneos/FlowReader.app "$STAGING/Payload/FlowReader.app"
test ! -e "$STAGING/Payload/FlowReader.app/embedded.mobileprovision"
rm -rf "$STAGING/Payload/FlowReader.app/_CodeSignature"
ditto -c -k --norsrc --keepParent "$STAGING/Payload" dist/FlowReader-1.0.0-unsigned.ipa
(cd dist && shasum -a 256 FlowReader-1.0.0-unsigned.ipa > SHA256SUMS.txt)
echo 'Unsigned IPA ready in dist/'
