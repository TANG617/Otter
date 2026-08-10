#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
cd "$repository_root"

failures=0

report_matches() {
    local title=$1
    local matches=$2
    if [[ -n "$matches" ]]; then
        print -u2 -- "$title"
        print -u2 -- "$matches"
        failures=$((failures + 1))
    fi
}

internal_timeline_matches=$(git grep -nEI '/(api/)?timeline/(bucket|buckets)([^[:alnum:]_]|$)' -- Otter 2>/dev/null || true)
report_matches "Forbidden Immich Internal timeline endpoint reference:" "$internal_timeline_matches"

scope_type_matches=$(git grep -nEI '\b(AssetUploader|UploadService|UploaderService|CameraRollBackup|BackgroundBackup|BackupService|OfflineLibraryManager)\b' -- Otter OtterTests OtterUITests 2>/dev/null || true)
report_matches "Forbidden uploader, backup, or durable offline-library artifact:" "$scope_type_matches"

scope_path_matches=$(git ls-files Otter OtterTests OtterUITests | grep -Ei '(^|/)(upload(er)?|backup|macos|maccatalyst)(/|[^/]*\.)' || true)
report_matches "Forbidden out-of-scope tracked path:" "$scope_path_matches"

platform_matches=$(git grep -nEI '(platform:[[:space:]]*macOS|SDKROOT[[:space:]]*=[[:space:]]*macosx|SUPPORTS_MACCATALYST[[:space:]]*=[[:space:]]*YES)' -- project.yml Config Otter.xcodeproj 2>/dev/null || true)
report_matches "Forbidden macOS or Mac Catalyst target setting:" "$platform_matches"

platform_source_matches=$(git grep -nEI '(import[[:space:]]+AppKit|#if[[:space:]]+os\(macOS\)|targetEnvironment\(macCatalyst\))' -- Otter OtterTests OtterUITests 2>/dev/null || true)
report_matches "Forbidden macOS or Mac Catalyst source artifact:" "$platform_source_matches"

private_key_matches=$(git grep -nE '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,})' -- ':!scripts/check-scope-regressions.sh' 2>/dev/null || true)
report_matches "Credential-shaped tracked content:" "$private_key_matches"

credential_query_matches=$(git grep -nEI 'https?://[^[:space:]"]+[?&](apiKey|api_key|x-api-key|token)=' -- Otter OtterUITests Config scripts 2>/dev/null || true)
report_matches "Credential-bearing URL query:" "$credential_query_matches"

environment_secret_matches=$(git grep -nE 'OTTER_TEST_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]#]+' -- Config scripts OtterTests OtterUITests 2>/dev/null || true)
report_matches "Nonempty tracked live-test credential assignment:" "$environment_secret_matches"

live_write_matches=$(git grep -nEI '(httpMethod[[:space:]]*=[[:space:]]*"(PUT|PATCH|DELETE)"|/api/(download|sync|admin)|rating)' -- 'OtterTests/Fixtures/LiveServer*' 2>/dev/null || true)
report_matches "Live-server harness must remain read-only (version/search/detail/thumbnail only):" "$live_write_matches"

tracked_local_config=$(git ls-files 'Config/Local.xcconfig' '*.local.xcconfig' '*.env' ':!scripts/live-server.env.example' || true)
report_matches "Tracked local configuration file:" "$tracked_local_config"

tracked_secret_file=$(git ls-files '*.pem' '*.p12' '*.pfx' '*.mobileprovision' || true)
report_matches "Tracked credential or provisioning file:" "$tracked_secret_file"

large_fixtures=""
while IFS= read -r -d '' fixture; do
    [[ -f "$fixture" ]] || continue
    bytes=$(stat -f '%z' "$fixture")
    if (( bytes > 524288 )); then
        large_fixtures+="${fixture} (${bytes} bytes)"$'\n'
    fi
done < <(git ls-files -z 'OtterTests/Fixtures/**' 'OtterUITests/Fixtures/**' '*.jpg' '*.jpeg' '*.png' '*.heic' '*.heif' '*.webp')
report_matches "Tracked fixture exceeds 512 KiB; generate it at runtime:" "${large_fixtures%$'\n'}"

if (( failures > 0 )); then
    print -u2 -- "Scope regression check failed with $failures category violation(s)."
    exit 1
fi

print -- "Scope regression check passed."
