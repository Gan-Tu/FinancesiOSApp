#!/bin/bash
set -euo pipefail
export OPENAI_API_KEY=""
export FINANCES_DISABLE_INFERENCE=1
cd "$(dirname "$0")/.."
FINANCES_TEST_SCHEME=FinancesiOSFullTests
FINANCES_TEST_MODE=core
case "${1:-}" in
  --smoke) FINANCES_TEST_SCHEME=FinancesiOS; FINANCES_TEST_MODE=smoke; shift ;;
  --full) FINANCES_TEST_MODE=full; shift ;;
  --core) shift ;;
  --help)
    cat <<'USAGE'
Usage: scripts/test.sh [--core | --smoke | --full] [xcodebuild test options]
  --core   Fast core behavior checks (default).
  --smoke  Exact Xcode Cloud release selection.
  --full   Complete unit and UI suite, including stress and performance checks.
An explicit -only-testing: selection runs only the requested regressions.
USAGE
    exit 0 ;;
esac
if [[ "$FINANCES_TEST_MODE" == core ]]; then
  for argument in "$@"; do
    if [[ "$argument" == -only-testing:* ]]; then
      FINANCES_TEST_MODE=targeted
      break
    fi
  done
fi
if [[ "$FINANCES_TEST_MODE" == core ]]; then
  while IFS= read -r identifier; do
    [[ -z "$identifier" || "$identifier" == \#* ]] && continue
    set -- "-only-testing:FinancesiOSTests/${identifier%()}" "$@"
  done < scripts/core-tests.txt
fi
python3 scripts/check_project.py
SIMULATOR_DESTINATION="${SIMULATOR_DESTINATION:-$(python3 scripts/prepare_simulator.py)}"
xcodebuild -project FinancesiOS.xcodeproj -scheme "$FINANCES_TEST_SCHEME" -configuration Debug \
  -destination "$SIMULATOR_DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "build/Tests-$(date +%s).xcresult" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test "$@"
