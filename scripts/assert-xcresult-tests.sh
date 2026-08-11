#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    print -u2 "usage: $0 RESULT_BUNDLE [MINIMUM_TEST_COUNT]"
    exit 64
fi

result_bundle=$1
minimum_test_count=${2:-1}

if [[ ! -d "$result_bundle" ]]; then
    print -u2 "Missing test result bundle: $result_bundle"
    exit 1
fi

# Xcode 16.4 exposes the structured test summary through this subcommand.
# Printing its help in CI makes the runner's accepted arguments part of the log.
xcrun xcresulttool help get test-results summary

summary_file=$(mktemp "${TMPDIR:-/tmp}/otter-xcresult-summary.XXXXXX")
trap 'rm -f "$summary_file"' EXIT
xcrun xcresulttool get test-results summary --path "$result_bundle" > "$summary_file"

total_test_count=$(/usr/bin/plutil -extract totalTestCount raw -o - "$summary_file")
failed_test_count=$(/usr/bin/plutil -extract failedTests raw -o - "$summary_file")

if [[ "$total_test_count" != <-> || "$failed_test_count" != <-> ]]; then
    print -u2 "xcresult summary did not contain numeric test counts."
    exit 1
fi

print "Executed tests: $total_test_count; failed tests: $failed_test_count"
if (( total_test_count < minimum_test_count )); then
    print -u2 "Expected at least $minimum_test_count executed tests, found $total_test_count."
    exit 1
fi

if (( failed_test_count != 0 )); then
    print -u2 "The result bundle contains $failed_test_count failed tests."
    exit 1
fi
