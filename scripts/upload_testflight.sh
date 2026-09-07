#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_project.py

# Upload the reviewed archive using the signed-in Xcode account, or CI API-key
# arguments supplied by the caller. App Store Connect processing follows upload.
options_directory="$(mktemp -d "${TMPDIR:-/tmp}/finances-testflight.XXXXXX")"
trap 'rm -rf "$options_directory"' EXIT
cp ExportOptions.plist "$options_directory/ExportOptions.plist"
/usr/libexec/PlistBuddy -c 'Set :destination upload' "$options_directory/ExportOptions.plist"
xcodebuild -exportArchive -archivePath build/FinancesiOS.xcarchive \
  -exportPath build/upload -exportOptionsPlist "$options_directory/ExportOptions.plist" "$@"
