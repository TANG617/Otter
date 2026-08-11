# Decision Log

This file records product and architectural decisions that should not be silently reversed during implementation.

A change is allowed, but it should update the relevant design document and add a new decision entry explaining why.

---

## D-001 — Product is a viewer, not a full Immich client

**Date:** 2026-08-10
**Status:** Accepted

Otter's core scope is:

> **Browse. View. Rate. Download.**

Uploader, camera-roll backup, automatic synchronization of local originals, and offline-library management are explicit non-goals.

**Reason:** Narrow scope lets engineering effort concentrate on Apple-Photos-class browsing performance and interaction quality.

---

## D-002 — Native iOS/iPadOS first

**Date:** 2026-08-10
**Status:** Accepted

- Target iPhone and iPad.
- Minimum deployment target: iOS/iPadOS 18+.
- macOS is not a current release target.

**Reason:** A simultaneous macOS product would add substantial viewer/input/window UX work without improving the first mobile product. Core infrastructure should remain reasonably decoupled from UI frameworks, but macOS compatibility must not slow the initial release.

---

## D-003 — Arbitrary Immich servers must be supported

**Date:** 2026-08-10
**Status:** Accepted

The released client must work with user-owned Immich servers with different versions and media derivative configuration.

The developer's server is a test target and may be adjusted for experiments, but no special server configuration may become a hidden product prerequisite.

**Implications:**

- observe/infer actual thumbnail and preview dimensions;
- isolate version/API differences;
- do not hard-code derivative sizes;
- do not depend on administrator-only configuration access.

---

## D-004 — Do not build the primary timeline on Immich Internal timeline APIs

**Date:** 2026-08-10
**Status:** Accepted

Immich currently marks `/timeline/*` endpoints as Internal. Otter should obtain asset metadata through stable supported APIs and build timeline grouping locally.

The stable sync stream may be used for incremental metadata updates where appropriate.

**Reason:** The timeline is the core product surface and should not depend on endpoints explicitly allowed to change without third-party compatibility guarantees.

---

## D-005 — Current Version is the default viewer rendition

**Date:** 2026-08-10
**Status:** Accepted

Viewer defaults to:

```text
Current Version
```

The user can explicitly switch to:

```text
Original
```

Current and Original are first-class `AssetVariant`s with separate cache identity.

**Reason:** The normal viewing experience should reflect the user's current Immich edits while preserving direct access to the original source.

---

## D-006 — Download asks which rendition to export

**Date:** 2026-08-10
**Status:** Superseded by D-030

Download/export must let the user choose:

- Current Version
- Original

The app must not silently substitute one for the other.

Original should preserve source bytes where the server API provides the original file. Export is a separate workflow from viewer caching.

---

## D-007 — No offline guarantee

**Date:** 2026-08-10
**Status:** Accepted

Otter's media disk cache is disposable performance infrastructure.

There is no promise that a photo, album, or time range is available offline unless a future product decision introduces a dedicated offline feature.

**Reason:** Offline guarantees introduce download manifests, durable synchronization, reconciliation, storage ownership, and background-transfer complexity that conflict with the focused viewer scope.

---

## D-008 — Default disk media cache is 2 GiB and user configurable

**Date:** 2026-08-10
**Status:** Accepted

Default:

```text
2 GiB
```

Settings should allow explicit alternative limits.

Cache identity is isolated by server/account, but the storage budget is global across accounts.

**Reason:** Large preview caches materially improve perceived performance, but this remains disposable cache rather than user-owned local storage.

---

## D-009 — First release does not require full HDR fidelity

**Date:** 2026-08-10
**Status:** Accepted

Initial image presentation targets SDR / Display P3.

Full HDR/gain-map fidelity is a later phase and may require original HEIC/HEIF retrieval and an HDR-aware decoding/presentation path.

**Reason:** HDR complicates source selection, network cost, decoding, memory pressure, and presentation. It should not block excellent normal browsing.

---

## D-010 — MediaPipeline is a first-class subsystem

**Date:** 2026-08-10
**Status:** Accepted

The product must not reduce image loading to `URL -> UIImage` inside views.

`MediaPipeline` owns:

- representation planning;
- request coalescing;
- priority scheduling;
- cancellation;
- progressive delivery;
- render memory cache;
- compressed byte disk cache;
- controlled decode/downsample;
- prefetch;
- instrumentation.

**Reason:** This is the subsystem that determines whether the viewer can approach Apple Photos-like perceived performance.

---

## D-011 — Byte cache and render cache have distinct identities

**Date:** 2026-08-10
**Status:** Accepted

One server preview file may produce multiple decoded target sizes.

Therefore:

```text
ByteCacheKey != RenderCacheKey
```

Network representation sharing and bitmap sharing are coordinated separately.

---

## D-012 — Shared media work uses consumer leases

**Date:** 2026-08-10
**Status:** Accepted

Multiple cells/viewers/prefetchers may depend on the same request.

Cancelling one consumer must not cancel work still required by another consumer. Underlying work is cancelled only when consumer ownership and scheduler policy allow it.

A prefetched task promoted to visible/interactive should normally reuse progress rather than restart.

---

## D-013 — Main-thread image decoding is prohibited

**Date:** 2026-08-10
**Status:** Accepted

Heavy decode/downsample work must execute on a controlled non-main decode queue/executor.

ImageIO/`CGImageSource` is the initial baseline decoder. Large original media remains file-backed and is decoded only to a bounded target size.

**Reason:** Main-thread image decode directly consumes the frame budget and is incompatible with the product's performance target.

---

## D-014 — UIKit is allowed when it improves the viewer

**Date:** 2026-08-10
**Status:** Accepted

Otter is SwiftUI-first for normal product UI, but “native” does not mean “SwiftUI-only.”

A UIKit-backed fullscreen viewer is acceptable if it provides better control over paging, `UIScrollView` zoom/pan, gesture arbitration, interactive dismissal, or geometry-preserving image replacement.

---

## D-015 — Performance must be measured, not assumed

**Date:** 2026-08-10
**Status:** Accepted

Pipeline and UI performance should be evaluated using Instruments and structured signposts/metrics.

Important targets include:

- no main-thread image decoding;
- no duplicate network transfer for the same byte key;
- no blank viewer frame after successful neighbor prefetch;
- stable memory envelope during prolonged browsing;
- bounded decode concurrency;
- cancellation of obsolete speculative work.

Optimizations without measurement should not override simpler correct behavior.

---

## D-016 — Product and repository name is Otter

**Date:** 2026-08-10
**Status:** Accepted

Primary brand:

> **Otter**

Recommended compatibility descriptor:

> **Otter for Immich**

or:

> **Otter — Native Photos for Immich**

The name evokes fluid, effortless movement rather than storage/backup. Product UI should not turn ordinary concepts into otter-themed novelty terms.

Functional engineering modules should generally use names such as `MediaPipeline`, `AssetStore`, and `ImmichKit` rather than adding an `Otter` prefix to every type/package.

---

## D-017 — MVP authentication uses an Immich API key

**Date:** 2026-08-10
**Status:** Accepted

Onboarding asks for an Immich Server URL and API key. The key is stored with device-only Keychain accessibility. Email/password and OAuth login are not implemented in the MVP.

The key is sent only through the `x-api-key` header and never appears in a URL, log, cache key, fixture, or error description.

---

## D-018 — MVP has one active account with namespaced identity

**Date:** 2026-08-10
**Status:** Accepted

The MVP has one active account and no complex account switcher. The account record owns a persistent random UUID namespace mapped to the normalized server and validated user. It is not derived from the API key.

Database, byte cache, render cache, invalidation, and clear operations remain account-scoped so a future multi-account UI does not require an identity migration.

---

## D-019 — GRDB and SQLite own local metadata persistence

**Date:** 2026-08-10
**Status:** Accepted

Use GRDB through Swift Package Manager for the metadata database and cache index. GRDB is the only initial third-party runtime dependency. A minimal direct SQLite3 wrapper is allowed only if the environment cannot resolve GRDB.

---

## D-020 — Start with one application module and two test targets

**Date:** 2026-08-10
**Status:** Accepted

The initial project has one native iOS application target, one unit test target, and one UI test target. Architectural boundaries are directories and type dependencies, not a speculative collection of framework or package targets.

---

## D-021 — Timeline starts SwiftUI-first

**Date:** 2026-08-10
**Status:** Accepted

The initial timeline uses lazy SwiftUI sections/grid with stable identity and paged data. A `UICollectionView` replacement requires focused performance evidence showing that the SwiftUI container cannot meet the viewer budget.

---

## D-022 — Fullscreen viewer combines SwiftUI and UIKit

**Date:** 2026-08-10
**Status:** Accepted

SwiftUI owns the fullscreen shell and overlays. A reusable UIKit surface owns horizontal paging and each page's `UIScrollView` zoom/pan interaction.

---

## D-023 — Export uses foreground file-backed downloads

**Date:** 2026-08-10
**Status:** Accepted

Current and Original exports use explicit foreground, file-backed `URLSession` download work. The MVP does not persist a background-transfer system. Current and Original are always user choices and are never silently substituted.

The destination and interaction details are amended by D-030; the file-backed transfer and no-substitution rules remain accepted.

---

## D-024 — Release networking keeps platform trust and narrow ATS policy

**Date:** 2026-08-10
**Status:** Accepted

Release builds do not disable TLS verification, trust arbitrary self-signed certificates, or set global `NSAllowsArbitraryLoads`. Local-network HTTP uses only the narrow Apple `NSAllowsLocalNetworking` exception and local-network usage disclosure.

“Arbitrary user-owned server” therefore means an API-compatible server reachable under the platform's release trust and transport rules.

---

## D-025 — Product and build defaults are centralized

**Date:** 2026-08-10
**Status:** Accepted

- Product and scheme: `Otter`
- Bundle identifier default: `com.tang617.otter`
- Deployment target: iOS/iPadOS 18.0
- Device families: iPhone and iPad
- Simulator builds require no Developer Team
- No macOS or Mac Catalyst target

---

## D-026 — API-key refresh uses search reconciliation, not sync stream

**Date:** 2026-08-10
**Status:** Accepted

Immich v3.1.0 labels `POST /sync/stream` Stable but explicitly rejects API-key authentication in the server implementation. That conflicts with combining the MVP API-key decision and an always-on sync-stream requirement.

The MVP therefore uses stable metadata search for bootstrap, an overlapping `updatedAfter` polling window for ordinary refresh, and periodic full reconciliation for deletes and offset-pagination gaps. The client exposes sync-stream capability as unavailable rather than attempting a known 403 path or claiming real-time sync.

If a future accepted authentication decision adds session authentication, the stable sync stream may be integrated behind the existing store boundary.

---

## D-027 — Rating write is a verified optional capability

**Date:** 2026-08-10
**Status:** Accepted

In Immich v3.1.0 the rating field supports `-1`, `1...5`, and `null`, but the only public write operation (`PUT /assets/{id}`) is Deprecated and has no public Stable replacement.

Otter isolates that operation as an optional capability. Optimistic UI always rolls back on failure, and a successful response is followed by an asset read to verify the persisted rating. Read-only external libraries and credentials without `asset.update` surface a precise unavailable state. Rating never changes media content identity.

The write-editor choices are narrowed by D-031; the server read contract and verified-write behavior remain accepted.

---

## D-028 — Timeline date and ordering are deterministic

**Date:** 2026-08-10
**Status:** Accepted

Timeline grouping uses Immich `localDateTime` first. It falls back to `fileCreatedAt`, then `createdAt`. Assets sort by the selected date descending and asset UUID string descending as a stable tie-breaker. Grouping is performed in the data layer using the user's current calendar/time-zone semantics.

---

## D-029 — Media invalidation and clearing are account-scoped

**Date:** 2026-08-10
**Status:** Accepted

The documented example `invalidate(assetID:)` is insufficient because asset UUIDs can collide across accounts. The implemented pipeline accepts the account namespace together with the asset ID. Disk clearing has explicit account-scoped and global operations; sign out always clears session/render state and does not expose the previous account's frames.

---

## D-030 — Viewer-selected rendition downloads directly to Photos

**Date:** 2026-08-11
**Status:** Accepted

The Viewer owns the explicit Current/Original selection. Pressing Download immediately starts a foreground, file-backed export of that selected rendition and saves it to Photos using add-only authorization. The core flow has no second rendition/destination sheet and no Files destination.

The selected asset ID and rendition are captured at task start. Switching photos, leaving the Viewer, or signing out cancels the consumer; stale completion cannot update the new photo. Current and Original are never silently substituted. Export remains separate from the disposable media cache.

**Reason:** The rendition is already visible and explicit in Viewer chrome. Re-asking adds friction and weakens the direct, native Photos interaction model.

---

## D-031 — Rating editor writes Unrated or one through five stars

**Date:** 2026-08-11
**Status:** Accepted

The rating editor exposes only Unrated and 1–5 stars. It does not expose a Reject write action. The domain and persistence layers continue to decode and retain Immich's existing `-1` value; a rejected asset is displayed as Rejected and the user may change it to an allowed editor value.

Favourite is an independent Boolean metadata field. Rating and Favourite mutations for one asset are serialized, verified by read-back, and roll back only their own optimistic field on failure. Neither field changes byte/render cache identity.

**Reason:** This preserves compatibility with existing server data while keeping the primary rating interaction aligned with the intended product choices.

---

# Open decisions

The following are intentionally not fixed yet:

1. Exact decode concurrency and cache memory budget per physical device class after profiling. Initial values remain one decode and approximately 128 MiB.
2. Whether rating filtering/search ships in the first public release or immediately after the viewer MVP.
3. Video and Live Photo phase ordering.
4. HDR source detection and rendering strategy.
5. Deep-zoom strategy beyond a bounded 4K/6K render.
6. Final App Store subtitle and trademark/name clearance for public commercial release.
