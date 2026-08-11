#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

cd "$repository_root"

result_root=$(mktemp -d "${TMPDIR:-/tmp}/otter-ui-results.XXXXXX")
trap 'rm -rf "$result_root"' EXIT

for simulator_name in 'iPhone 17 Pro' 'iPad Pro 13-inch (M5)'; do
    result_bundle="$result_root/${simulator_name// /_}.xcresult"
    xcodebuild test \
        -project Otter.xcodeproj \
        -scheme Otter \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=${simulator_name}" \
        -derivedDataPath .build/DerivedData \
        -resultBundlePath "$result_bundle" \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:OtterUITests/OtterUITests
    scripts/assert-xcresult-tests.sh "$result_bundle" 9
done
