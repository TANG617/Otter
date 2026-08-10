# Implementation Status

This file records verified implementation status. “Planned” is never equivalent to complete.

| Requirement | Implementation | Test/evidence | Status | Known limitation |
|---|---|---|---|---|
| iOS/iPadOS app, Swift 6 strict concurrency | `project.yml`, `Otter.xcodeproj`, `Config/*.xcconfig` | simulator build | In progress | Only iOS 27 runtime is installed; iOS 18 runtime regression remains required. |
| App/unit/UI targets | Xcode project targets | skeleton unit/UI tests | In progress | Initial skeleton only. |
| Dependency-injection root | `AppEnvironment`, `AppSession`, `AppRoute` | skeleton test | In progress | Feature dependencies not wired yet. |
| Deterministic fixture launch | `AppEnvironment.makeDefault` | `OtterUITests.testFixtureLaunchesLibraryShell` | In progress | Fixture media/store not built yet. |
| API-key onboarding and Keychain | — | — | Planned | — |
| Immich compatibility/client | `docs/immich-api-contract.md` | — | Planned | API-key sync stream is unavailable by official server design. |
| GRDB metadata store and reconciliation | — | — | Planned | — |
| Media planner/cache/coalescing/scheduler/decoder | — | — | Planned | — |
| Timeline | — | — | Planned | — |
| Fullscreen UIKit viewer | — | — | Planned | — |
| Rating rollback | — | — | Planned | Public write endpoint is deprecated in Immich v3.1.0. |
| Current/Original export | — | — | Planned | — |
| Settings and diagnostics | — | — | Planned | — |
| iPhone/iPad UI smoke | — | — | Planned | — |
| Performance and memory validation | `docs/performance-baseline.md` | — | Planned | Requires implemented flows. |
| Live Immich integration | — | environment-gated tests | Not verified | No credential has been provided. |

