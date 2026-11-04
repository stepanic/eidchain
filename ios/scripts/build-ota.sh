#!/bin/bash
# Build a development-signed IPA and publish it for OTA install over Tailscale.
# The phone's UDID must be in the ITalk team (automatic signing puts every
# registered device into the development profile).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OTA_DIR:-$HOME/.cache/eoinfc-ota}"
KEY=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_25KYCN22QD.p8"
     -authenticationKeyID 25KYCN22QD -authenticationKeyIssuerID 69a6de85-f7cc-47e3-e053-5b8c7c11a4d1)
VERSION="$(date +%Y%m%d%H%M)"
xcodegen -q
xcodebuild -quiet -project EOINFC.xcodeproj -scheme EOINFC -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/EOINFC.xcarchive \
  CURRENT_PROJECT_VERSION="$VERSION" -allowProvisioningUpdates "${KEY[@]}" archive
xcodebuild -quiet -exportArchive -archivePath build/EOINFC.xcarchive -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates "${KEY[@]}"
mkdir -p "$OUT"
cp build/export/*.ipa "$OUT/EOINFC.ipa"
sed "s/@VERSION@/$VERSION/" scripts/manifest.plist.in > "$OUT/manifest.plist"
echo "https://ms.tailf0e6eb.ts.net/eoinfc/  (build $VERSION)"
