# Implementation Status

Verified on 11 August 2026. “Complete” means implemented and covered by the evidence in this repository or the simulator runs listed below; it does not imply unperformed physical-device validation.

| Requirement | Implementation | Test/evidence | Status | Known limitation |
|---|---|---|---|---|
| iOS/iPadOS app, Swift 6 strict concurrency | `project.yml`, `Otter.xcodeproj`, `Config/*.xcconfig` | local generic dual-architecture build; CI build on Xcode 16.4 / iOS 18.5 | Complete | Local profiling used Xcode 27.0 beta / iOS 27.0 because no local iOS 18 runtime is installed. |
| App/unit/UI targets | Xcode project targets | 167 unit tests passed; 9 iPhone and 9 iPad local UI flows passed | Complete | Three opt-in live tests skip without environment credentials. Broader physical-device validation remains a release gate. |
| Dependency-injection and session root | `AppEnvironment`, `AppSession`, `AppRoute` | app/session/account tests | Complete | A new credential intentionally receives a fresh account namespace; safe isolation is preferred over cache reuse. |
| Deterministic 10k/100k fixtures | `FixtureAppRuntime`, `FixtureLibrary` | fixture tests and 100k simulator profile | Complete | Synthetic images model load/cancellation but not every server codec. |
| API-key onboarding and Keychain | `OnboardingView`, `KeychainAPIKeyStore`, `ActiveAccountStore` | onboarding, normalization, account-isolation and sign-out tests | Complete | API key is device-only and must be entered again after reinstall/restore. |
| Immich v3 compatibility/client | `ImmichClient`, DTOs, endpoint builders | URLProtocol contract tests and read-only Immich v3.1.0 run | Complete | Major versions other than 3 are capability-gated best effort. API-key sync stream is unavailable by server design. |
| GRDB metadata and reconciliation | `AssetDatabase`, `LocalFirstAssetStore` | pagination, overlap-window, full-reconciliation and 100k DB tests | Complete | Offset pagination is reconciled periodically because concurrent server mutations can create gaps. |
| Media planner/cache/coalescing/scheduler/decoder | `Infrastructure/Media*` | planner, fallback, cache, retry, cancellation and scheduler tests | Complete | WebP/Photos interoperability still requires iOS 18 fixture/device confirmation. |
| Timeline | `TimelineView`, `TimelineState`, `TimelineMediaCell` | 10k metadata update, 100-page append, dedup/grouping/prefetch, and UI flows | Complete | Metadata-only updates patch one asset/section; ordered pages extend trailing sections, with counted rebuild fallback for order/date changes. |
| Fullscreen viewer and UIKit zoom surface | `FullscreenViewer`, `ViewerFilmstrip`, `ZoomingMediaSurface` | focused paging/filmstrip/zoom lifecycle tests plus UI gestures | Complete | Paging uses interactive SwiftUI offsets driven by the UIKit surface; no page-style `TabView` remains. Filmstrip thumbnail work is separate and bounded. |
| Rating and Favourite with rollback | `RatingRepository`, Viewer controls | same-asset serialization, independent rollback, accessibility, and failure UI tests | Complete | Editor choices are Unrated/1–5; existing server `-1` remains readable/displayable as Rejected. Writes are capability-gated and verified by read-back. |
| Direct Current/Original download | `AssetExporter`, `DirectPhotosDownload`, `PhotosExporter` | rendition capability, no-fallback, cancellation cleanup, and direct-download UI tests | Complete | Viewer-selected rendition saves directly to Photos with add-only permission; no second sheet or Files core flow. WebP still needs device validation. |
| Settings and diagnostics | `SettingsView`, `DiagnosticsView` | navigation, clear-cache, summary and sign-out UI flows | Complete | Diagnostics deliberately omit endpoint and credential material. |
| Authentication failure and cleanup | shared invalidation stream, account-scoped cache/DB cleanup | 401 and active-lease cleanup tests; read-only live sign-out inspection | Complete | Cleanup failure is surfaced rather than silently reported as success. |
| Performance and memory validation | `docs/performance-baseline.md` | ETTrace and memgraph artifacts under ignored `.codex-artifacts/` | Simulator baseline complete | Physical iPhone/iPad Instruments and iOS 18 performance/memory runs remain release gates. |
| Live Immich integration | live runtime and opt-in harness | read-only v3.1.0 connection, 41,000-asset sync, real thumbnail timeline, Viewer paging, sign-out cleanup | Read-only verified | No rating, Original, export, archive, or other server write was attempted. |

## Latest verification summary

- Unit: 170 discovered; 167 passed, 0 failed, 3 skipped because live credentials were not injected into that run.
- iPhone 17 Pro / iOS 27.0: all 9 UI tests passed.
- iPad Pro 13-inch (M5) / iOS 27.0: all 9 UI tests passed (5 Viewer-heavy and 4 remaining flows, split only to stay within the automation tool timeout).
- GitHub Actions runs Xcode 16.4 / iPhone 16 Pro / iOS 18.5 dependency resolution, generic build, all unit tests, and the complete 9-test fixture UI suite. Both test steps parse `.xcresult`; a zero/short UI selection fails even if `xcodebuild` exits successfully.
- Read-only live server: authenticated to Immich v3.1.0, rendered real library thumbnails, paged the Viewer, then signed out. Post-sign-out inspection found zero accounts, assets, and sync-state rows, and no cached media byte files.
- No API key, server address, or live response body is tracked in the repository.
