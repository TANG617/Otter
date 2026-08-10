# Otter Engineering Guide

## Read first

Before changing code, read `docs/README.md` and the design document relevant to the work. `docs/product.md`, `docs/architecture.md`, `docs/media-pipeline.md`, and accepted entries in `docs/decisions.md` are authoritative unless the task prompt explicitly says otherwise.

## Product and architecture boundaries

- Otter is a viewer centered on Browse, View, Rate, and Download. It is not a complete Immich client.
- Do not add upload, camera-roll backup, background backup, durable offline-library, delete/trash, administration, video, Live Photo, RAW, HDR, tiled deep zoom, macOS, or Mac Catalyst behavior.
- UI never calls Immich endpoints directly. UI expresses demand through `AssetStore`, `MediaPipeline`, and `AssetExporter` boundaries.
- `AssetStore` owns metadata and timeline membership; it never decodes pixels.
- `MediaPipeline` owns media delivery and never owns timeline membership.
- Explicit export produces a user-owned file and is not a cache side effect.
- Immich DTOs are converted to domain values at the infrastructure boundary and never enter SwiftUI views.
- Never use Immich Internal `/timeline/*` endpoints as a core dependency.

## Media and concurrency invariants

- Image decode/downsample must not execute on the main thread.
- Timeline must never request Original or speculative fullsize media.
- Rating is metadata only. It must not change media content revisions or invalidate pixel cache entries.
- Current and Original use distinct byte/render cache identity unless content equivalence has been proven.
- Large media stays file-backed: never implement `URL -> Data -> UIImage` for large images.
- Shared requests use consumer leases. Releasing one consumer must not cancel work still needed by another.
- Do not create unbounded `Task`s or unlimited network/decode work. Use the scheduler lanes.
- Async streams must release continuations and leases on termination.
- API keys must never appear in URLs, logs, errors, cache keys, test fixtures, or analytics.

## Implementation style

- Prefer the smallest correct implementation and explicit ownership.
- Default to MV with narrow local state; do not create a ViewModel for every screen.
- Introduce a protocol only for a real system boundary, test substitution point, multiple implementation, or isolation boundary.
- Do not add unused adapters, generic manager/repository/factory base classes, event buses, DI frameworks, or speculative packages.
- Keep sorting, grouping, JSON parsing, decoding, and network calls out of SwiftUI `body`.
- Split a SwiftUI view around 300 lines into meaningful subview types.
- Use stable domain IDs for lazy timeline/viewer content.
- All behavior changes require proportionate unit, integration, or UI coverage.

## Project generation

The generated `Otter.xcodeproj` is committed, so XcodeGen is not required for ordinary builds. When `project.yml` or target settings change, regenerate with the single supported command:

```sh
xcodegen generate --spec project.yml
```

Commit `project.yml` and the regenerated project together.

## Build and test

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

xcodebuild test \
  -project Otter.xcodeproj \
  -scheme Otter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Run fixture mode with launch arguments:

```text
-OTTER_USE_FIXTURES YES
```

Live integration tests read `OTTER_TEST_SERVER_URL` and `OTTER_TEST_API_KEY` from the environment. Never commit their values.

## XcodeBuildMCP flow

1. Call `session_show_defaults` before the first build/run/test call.
2. Set `Otter.xcodeproj`, scheme `Otter`, Debug, and an iPhone simulator with `session_set_defaults`.
3. Use `build_sim` or `test_sim`; do not drive UI after a failed build.
4. Use `build_run_sim` with `-OTTER_USE_FIXTURES YES`.
5. Verify launch with `snapshot_ui` or `screenshot`, then interact by accessibility identifiers.
6. Repeat build/run smoke with an iPad simulator.
7. Capture logs and check for crashes, concurrency warnings, duplicate transfers, and main-thread decode assertions.

## Repository hygiene

- Never commit credentials, `DerivedData`, `.build`, `.xcresult`, screenshots, traces, memgraphs, or local xcconfigs.
- Put local evidence under `.codex-artifacts/` or `Artifacts/`; both are ignored.
- Do not force-push or rewrite published history.
- Before handoff, run the relevant build/tests and finish with a clean `git status`.

