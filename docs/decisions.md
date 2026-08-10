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
**Status:** Accepted

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

# Open decisions

The following are intentionally not fixed yet:

1. Exact timeline container implementation (`LazyVGrid` vs. `UICollectionView`) after profiling.
2. Exact local metadata database technology (for example GRDB/SQLite vs. another lightweight persistence approach).
3. Exact decode concurrency and cache memory budget per device class.
4. Authentication UX and API-key provisioning flow.
5. Whether rating filtering/search ships in the first public release or immediately after the viewer MVP.
6. Video and Live Photo phase ordering.
7. HDR source detection and rendering strategy.
8. Deep-zoom strategy beyond a bounded 4K/6K render.
9. Final App Store subtitle and trademark/name clearance for public commercial release.
