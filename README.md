# Otter

Otter — Native Photos for Immich.

Otter is a focused, native iPhone and iPad photo viewer for browsing an Immich library. Its product scope is deliberately limited to four actions: Browse, View, Rate, and Download.

## Requirements

- Xcode 16 or newer with an iOS 18+ SDK. The recorded local verification used Xcode 27.0 beta because it is the only installed toolchain.
- iPhone or iPad simulator
- No developer team is required for simulator builds

The generated Xcode project and resolved package graph are committed. XcodeGen is needed only when editing `project.yml`.

## Build

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcodebuild -resolvePackageDependencies \
  -project Otter.xcodeproj \
  -scheme Otter \
  -clonedSourcePackagesDirPath .build/SourcePackages

xcodebuild build \
  -project Otter.xcodeproj \
  -scheme Otter \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Test

```sh
xcodebuild test \
  -project Otter.xcodeproj \
  -scheme Otter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Fixture UI tests launch the app with `-OTTER_USE_FIXTURES YES` and require no Immich credentials. Live integration tests use `OTTER_TEST_SERVER_URL` and `OTTER_TEST_API_KEY`; when either is absent, those tests skip with an explicit reason.

The CI and local smoke scripts write `.xcresult` bundles and verify that the expected tests actually executed; a zero-test selection fails the run.

For a 100,000-asset deterministic stress run:

```sh
xcrun simctl launch booted com.tang617.otter \
  -OTTER_USE_FIXTURES YES \
  -OTTER_FIXTURE_ASSET_COUNT 100000
```

## Project regeneration

After editing `project.yml`:

```sh
xcodegen generate --spec project.yml
```

Ordinary contributors do not need XcodeGen because `Otter.xcodeproj` is committed.

## Local configuration

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` only for local build-setting overrides. Set `OTTER_DEVELOPMENT_TEAM` there when a signed device/archive build needs your Apple Team ID. Simulator builds remain team-independent with `CODE_SIGNING_ALLOWED=NO`. Credentials never belong in xcconfig or schemes, and `Config/Local.xcconfig` is ignored by Git.

## Documentation

Start with [docs/README.md](docs/README.md). The consolidated output of the 10 August 2026 implementation round—including delivered features, test methods/results, live read-only verification, and performance metrics—is in [docs/execution-report-2026-08-10.md](docs/execution-report-2026-08-10.md). Requirement status is recorded in [docs/implementation-status.md](docs/implementation-status.md), the measured simulator baseline is in [docs/performance-baseline.md](docs/performance-baseline.md), and the exact Immich surface is recorded in [docs/immich-api-contract.md](docs/immich-api-contract.md).
