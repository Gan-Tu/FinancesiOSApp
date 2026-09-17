#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${ASSISTANT_SIMULATOR:-}" ]]; then
  ASSISTANT_SIMULATOR="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); matches=[v["udid"] for rows in d["devices"].values() for v in rows if v["name"] == "Finances Assistant"]; assert matches, "Set ASSISTANT_SIMULATOR to your test device UDID"; print(matches[0])')"
fi
ASSISTANT_BUILD_DIR="${ASSISTANT_BUILD_DIR:-build/AssistantDerivedData}"
export OPENAI_API_KEY=""
export FINANCES_DISABLE_INFERENCE=1
# The app uses AssistantMockGateway. No local backend or API key is required.
xcodebuild -project FinancesiOS.xcodeproj -scheme FinancesiOSFullTests -configuration Debug \
  -destination "platform=iOS Simulator,id=$ASSISTANT_SIMULATOR" -derivedDataPath "$ASSISTANT_BUILD_DIR" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
python3 - "$ASSISTANT_BUILD_DIR" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])/'Build/Products'
source=max(root.glob('FinancesiOSFullTests*.xctestrun'),key=lambda p:p.stat().st_mtime)
data=plistlib.loads(source.read_bytes())
targets=[]
for config in data.get('TestConfigurations',[]):
 targets.extend(target for target in config.get('TestTargets',[]) if target.get('BlueprintName')=='FinancesiOSUITests')
if 'FinancesiOSUITests' in data:
 targets.append(data['FinancesiOSUITests'])
assert len(targets)==1, 'Could not find the UI test runner in the generated xctestrun'
targets[0].setdefault('EnvironmentVariables',{})['FINANCES_MOCK_ASSISTANT_TESTS']='1'
destination=root/'AssistantLocal.xctestrun'
destination.write_bytes(plistlib.dumps(data))
PY
xcodebuild -xctestrun "$ASSISTANT_BUILD_DIR/Build/Products/AssistantLocal.xctestrun" \
  -destination "platform=iOS Simulator,id=$ASSISTANT_SIMULATOR" \
  "-only-testing:FinancesiOSUITests/${ASSISTANT_UI_TEST:-AssistantInteractionTests/testLocalAssistantRoundTrip}" \
  -collect-test-diagnostics never test-without-building
