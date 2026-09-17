#!/bin/bash
set -euo pipefail
export OPENAI_API_KEY=""
export FINANCES_DISABLE_INFERENCE=1
cd "$(dirname "$0")/.."
FINANCES_TEST_SCHEME=FinancesiOSFullTests
if [[ "${1:-}" == "--smoke" ]]; then
  FINANCES_TEST_SCHEME=FinancesiOS
  shift
fi
python3 scripts/check_project.py
SIMULATOR_DESTINATION="${SIMULATOR_DESTINATION:-$(python3 scripts/prepare_simulator.py)}"
xcodebuild -project FinancesiOS.xcodeproj -scheme "$FINANCES_TEST_SCHEME" -configuration Debug \
  -destination "$SIMULATOR_DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "build/Tests-$(date +%s).xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test "$@"
