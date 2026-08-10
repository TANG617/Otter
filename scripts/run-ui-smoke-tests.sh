#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

cd "$repository_root"

for simulator_name in 'iPhone 17 Pro' 'iPad Pro 13-inch (M5)'; do
    xcodebuild test \
        -project Otter.xcodeproj \
        -scheme Otter \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=${simulator_name}" \
        -derivedDataPath .build/DerivedData \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:OtterUITests/OtterUITests
done
