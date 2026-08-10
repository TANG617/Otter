# Implementation Status

Verified on 10 August 2026. “Complete” means implemented and covered by the evidence in this repository or the simulator runs listed below; it does not imply unperformed iOS 18 or physical-device validation.

| Requirement | Implementation | Test/evidence | Status | Known limitation |
|---|---|---|---|---|
| iOS/iPadOS app, Swift 6 strict concurrency | `project.yml`, `Otter.xcodeproj`, `Config/*.xcconfig` | generic dual-architecture Simulator build | Complete | Local validation used Xcode 27.0 beta and iOS 27.0 because no iOS 18 runtime is installed. |
| App/unit/UI targets | Xcode project targets | 111 unit tests passed; 5 iPhone and 2 iPad UI flows passed | Complete | Three opt-in live tests skip without environment credentials. |
| Dependency-injection and session root | `AppEnvironment`, `AppSession`, `AppRoute` | app/session/account tests | Complete | A new credential intentionally receives a fresh account namespace; safe isolation is preferred over cache reuse. |
| Deterministic 10k/100k fixtures | `FixtureAppRuntime`, `FixtureLibrary` | fixture tests and 100k simulator profile | Complete | Synthetic images model load/cancellation but not every server codec. |
| API-key onboarding and Keychain | `OnboardingView`, `KeychainAPIKeyStore`, `ActiveAccountStore` | onboarding, normalization, account-isolation and sign-out tests | Complete | API key is device-only and must be entered again after reinstall/restore. |
| Immich v3 compatibility/client | `ImmichClient`, DTOs, endpoint builders | URLProtocol contract tests and read-only Immich v3.1.0 run | Complete | Major versions other than 3 are capability-gated best effort. API-key sync stream is unavailable by server design. |
| GRDB metadata and reconciliation | `AssetDatabase`, `LocalFirstAssetStore` | pagination, overlap-window, full-reconciliation and 100k DB tests | Complete | Offset pagination is reconciled periodically because concurrent server mutations can create gaps. |
| Media planner/cache/coalescing/scheduler/decoder | `Infrastructure/Media*` | planner, fallback, cache, retry, cancellation and scheduler tests | Complete | WebP/Photos interoperability still requires iOS 18 fixture/device confirmation. |
| Timeline | `TimelineView`, `TimelineState`, `TimelineMediaCell` | paging/dedup/grouping/prefetch tests and iPhone/iPad UI flows | Complete | Section counts show loaded count with `+` while more pages remain. |
| Fullscreen viewer and UIKit zoom surface | `FullscreenViewer`, `ZoomingMediaSurface` | 13 focused viewer tests plus UI flows | Complete | Pager orchestration is SwiftUI page-style `TabView`; zoom/pan/fit/double-tap are UIKit-backed. |
| Rating with rollback | `RatingRepository`, Viewer controls | serialized mutation, rollback and failure UI tests | Complete | Immich v3.1 marks the public asset-update operation deprecated; write is capability-gated and verified with a read-back. Live server rating was not changed during the authorized read-only run. |
| Current/Original export | `AssetExporter`, `ExportOptionsView` | exporter and unavailable-variant UI tests | Complete | Photos codec behavior, especially WebP, still needs iOS 18 device validation. |
| Settings and diagnostics | `SettingsView`, `DiagnosticsView` | navigation, clear-cache, summary and sign-out UI flows | Complete | Diagnostics deliberately omit endpoint and credential material. |
| Authentication failure and cleanup | shared invalidation stream, account-scoped cache/DB cleanup | 401 and active-lease cleanup tests; read-only live sign-out inspection | Complete | Cleanup failure is surfaced rather than silently reported as success. |
| Performance and memory validation | `docs/performance-baseline.md` | ETTrace and memgraph artifacts under ignored `.codex-artifacts/` | Simulator baseline complete | Physical iPhone/iPad Instruments and iOS 18 runtime remain release gates. |
| Live Immich integration | live runtime and opt-in harness | read-only v3.1.0 connection, 41,000-asset sync, real thumbnail timeline, Viewer paging, sign-out cleanup | Read-only verified | No rating, Original, export, archive, or other server write was attempted. |

## Latest verification summary

- Unit: 114 discovered; 111 passed, 0 failed, 3 skipped because live credentials were not injected into that run.
- iPhone 17 Pro / iOS 27.0: 5 UI tests passed.
- iPad Pro 13-inch (M5) / iOS 27.0: 2 key UI tests passed.
- Read-only live server: authenticated to Immich v3.1.0, rendered real library thumbnails, paged the Viewer, then signed out. Post-sign-out inspection found zero accounts, assets, and sync-state rows, and no cached media byte files.
- No API key, server address, or live response body is tracked in the repository.
