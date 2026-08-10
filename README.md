# Otter

Otter — Native Photos for Immich.

Otter is a focused, native iPhone and iPad photo viewer for browsing an Immich library. Its product scope is deliberately limited to four actions: Browse, View, Rate, and Download.

## Requirements

- Xcode 16 or newer with an iOS 18+ SDK
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

## Project regeneration

After editing `project.yml`:

```sh
xcodegen generate --spec project.yml
```

Ordinary contributors do not need XcodeGen because `Otter.xcodeproj` is committed.

## Local configuration

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` only for local build-setting overrides. Credentials never belong in xcconfig or schemes.

## Documentation

Start with [docs/README.md](docs/README.md). The implementation status and known limitations are recorded in [docs/implementation-status.md](docs/implementation-status.md), and the exact Immich surface is recorded in [docs/immich-api-contract.md](docs/immich-api-contract.md).

