#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_project.py
# The app's Release entitlements select the shared Production CloudKit database.
# Additional arguments allow CI to pass its signing profile and unique build number.
xcodebuild -project FinancesiOS.xcodeproj -scheme FinancesiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/FinancesiOS.xcarchive \
  -derivedDataPath build/ArchiveDerivedData "$@" archive
