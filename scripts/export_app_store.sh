#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_project.py
# Export only. Upload is a separate, explicitly selected workflow action.
xcodebuild -exportArchive -archivePath build/FinancesiOS.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist "$@"
