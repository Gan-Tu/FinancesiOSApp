#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_project.py
SIMULATOR_DESTINATION="${SIMULATOR_DESTINATION:-$(python3 scripts/prepare_simulator.py)}"
xcodebuild -project FinancesiOS.xcodeproj -scheme FinancesiOS -configuration Debug \
  -destination "$SIMULATOR_DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "build/Tests-$(date +%s).xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test "$@"
