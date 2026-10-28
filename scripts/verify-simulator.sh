#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
simulator_id="${1:?Usage: verify-simulator.sh <simulator UUID> [XCTest selectors]}"
shift
if [[ ! "$simulator_id" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    echo 'Expected an explicit Simulator UUID.' >&2
    exit 2
fi
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_base="$task_root/QA/Simulator-$run_stamp"
mkdir -p "$task_root/QA"
build_args=(-project "$task_root/ExViewer.xcodeproj" -scheme ExViewer -configuration Debug
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$task_root/build/Simulator"
    -parallel-testing-enabled NO -jobs 2 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
xcodebuild "${build_args[@]}" build-for-testing > "$run_base-build.log" 2>&1
codesign --verify --deep --strict "$task_root/build/Simulator/Build/Products/Debug-iphonesimulator/ExViewer.app"
# Normal signing also embeds Simulator application identity for Keychain. Do not disable it.
echo 'Running tests will restart ExViewer on the selected Simulator. QA fixtures use separate local data.'
xcodebuild "${build_args[@]}" -resultBundlePath "$run_base.xcresult" "$@" test-without-building > "$run_base-test.log" 2>&1
echo "Results: $run_base.xcresult"
