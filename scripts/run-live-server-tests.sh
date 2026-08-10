#!/bin/zsh
set -euo pipefail

if [[ ${OTTER_RUN_LIVE_SERVER_TESTS:-} != "YES" ]]; then
    print -u2 -- "Set OTTER_RUN_LIVE_SERVER_TESTS=YES to opt in."
    exit 64
fi

if [[ -z ${OTTER_TEST_SERVER_URL:-} || -z ${OTTER_TEST_API_KEY:-} ]]; then
    print -u2 -- "OTTER_TEST_SERVER_URL and OTTER_TEST_API_KEY must be set in the environment."
    exit 64
fi

if [[ ${OTTER_TEST_SERVER_URL} != http://* && ${OTTER_TEST_SERVER_URL} != https://* ]]; then
    print -u2 -- "OTTER_TEST_SERVER_URL must use HTTP or HTTPS."
    exit 64
fi

if [[ ${OTTER_TEST_SERVER_URL} == *\?* || ${OTTER_TEST_SERVER_URL} == *\#* || ${OTTER_TEST_SERVER_URL} == *\@* ]]; then
    print -u2 -- "OTTER_TEST_SERVER_URL must not contain credentials, query, or fragment."
    exit 64
fi

if [[ ${OTTER_TEST_API_KEY} == *[[:space:]]* ]]; then
    print -u2 -- "OTTER_TEST_API_KEY must not contain whitespace."
    exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

cd "$repository_root"
exec xcodebuild test \
    -project Otter.xcodeproj \
    -scheme Otter \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath .build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:OtterTests/LiveServerConfigurationTests \
    -only-testing:OtterTests/LiveServerReadOnlyTests
