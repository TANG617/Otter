# Architecture

## 1. Architectural objective

Otter should be structured as a **viewer product with an Immich backend**, not as a thin collection of views that call Immich endpoints directly.

The system has four major responsibilities:

1. **Metadata ownership** — know what assets exist, how they are ordered, and which metadata changed.
2. **Media delivery** — turn an asset request into the best frame available under current size, priority, cache, and network conditions.
3. **Presentation** — timeline, fullscreen viewer, gestures, rating, and export UI.
4. **Server compatibility** — isolate Immich API/version/configuration differences from the rest of the app.

The media-delivery path is the primary performance-critical subsystem.

---

## 2. High-level structure

```text
┌──────────────────────────────────────────────┐
│                    UI                        │
│                                              │
│ Timeline        Fullscreen Viewer    Rating │
└──────────────┬──────────────┬────────────────┘
               │              │
               ▼              ▼
       ┌──────────────┐  ┌──────────────┐
       │  AssetStore  │  │ MediaPipeline│
       └───────┬──────┘  └──────┬───────┘
               │                │
               ▼                ├── Render Memory Cache
       Local Metadata DB        ├── Byte Disk Cache
               │                ├── Request Coordinator
               │                ├── Scheduler / Prefetch
               │                └── Decoder
               │                         │
               └──────────┬──────────────┘
                          ▼
                  Immich Compatibility
                          │
                          ▼
                     URLSession
                          │
                          ▼
                    Immich Server
```

A separate `AssetExporter` owns explicit file-backed downloads and `PhotosExporter` owns add-only Photos insertion. Export is not a side effect of viewer caching.

---

## 3. Suggested package/module layout

```text
Otter/
├── App/
│
├── Packages/
│   ├── MediaCore/
│   │   ├── MediaAssetDescriptor.swift
│   │   ├── AssetVariant.swift
│   │   ├── MediaRequest.swift
│   │   ├── MediaFrame.swift
│   │   ├── RenderSurface.swift
│   │   ├── CacheKeys.swift
│   │   └── MediaError.swift
│   │
│   ├── ImmichKit/
│   │   ├── AuthenticationProvider.swift
│   │   ├── ImmichAPI.swift
│   │   ├── ImmichCompatibility.swift
│   │   ├── ServerCapabilities.swift
│   │   └── HTTPResponseValidator.swift
│   │
│   ├── AssetStore/
│   │   ├── AssetRepository.swift
│   │   ├── AssetDatabase.swift
│   │   ├── SyncEngine.swift
│   │   └── RatingRepository.swift
│   │
│   ├── MediaCache/
│   │   ├── RenderMemoryCache.swift
│   │   ├── ByteDiskCache.swift
│   │   ├── CacheDatabase.swift
│   │   └── CacheEvictor.swift
│   │
│   ├── MediaPipeline/
│   │   ├── MediaPipeline.swift
│   │   ├── RepresentationPlanner.swift
│   │   ├── RequestCoordinator.swift
│   │   ├── WorkScheduler.swift
│   │   ├── ImageDecoder.swift
│   │   ├── ImageIODecoder.swift
│   │   └── MediaMetrics.swift
│   │
│   ├── MediaUI/
│   │   ├── TimelineMediaView.swift
│   │   ├── ViewerMediaView.swift
│   │   └── ZoomingImageView.swift
│   │
│   └── AssetExport/
│       ├── AssetExporter.swift
│       └── PhotosExporter.swift
```

The exact package boundaries may be collapsed early if build complexity outweighs value, but the **dependency boundaries** below should remain.

---

## 4. Dependency rules

### UI must not call Immich directly

Bad:

```text
TimelineCell -> URLSession -> /assets/{id}/thumbnail
```

Good:

```text
TimelineCell -> MediaPipeline -> ImmichKit
```

UI describes demand. Infrastructure decides how to satisfy it.

### MediaPipeline must not own timeline metadata

`MediaPipeline` receives a stable `MediaAssetDescriptor`. It does not decide which assets belong in the library, date sections, albums, or filters.

### AssetStore must not decode images

`AssetStore` owns metadata and synchronization. Pixel delivery belongs to `MediaPipeline`.

### Export must not be disguised cache behavior

An explicit Download action uses `AssetExporter`. Cached media remains disposable.

### Immich DTOs must not leak throughout the app

Convert network DTOs into Otter domain types at the compatibility/repository boundary.

This protects the app from Immich schema/version churn and makes offline tests possible with local fixtures.

---

## 5. Core domain models

### Asset variant

```swift
enum AssetVariant: Hashable, Sendable {
    case current
    case original
}
```

### Media descriptor

```swift
struct MediaAssetDescriptor: Hashable, Sendable {
    let accountNamespace: UUID
    let id: UUID
    let type: MediaAssetType

    let checksum: String
    let thumbhash: String?

    let hasEdits: Bool
    let contentRevision: String
    let editedContentRevision: String?

    let originalWidth: Int?
    let originalHeight: Int?
    let originalMimeType: String?
}
```

The descriptor should contain only information required for media planning/cache identity. It should not become a copy of the full Immich `AssetResponseDto`.

### Render surface

The initial iOS-only product can bridge directly to UIKit at presentation time, but the core pipeline should preferably represent decoded pixels as an immutable `CGImage`-backed surface:

```swift
final class RenderSurface: @unchecked Sendable {
    let cgImage: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let estimatedByteCost: Int
}
```

The `@unchecked Sendable` boundary must be narrow and justified: the wrapper is immutable after construction.

This keeps the decoder/image cache independent of SwiftUI and avoids embedding view-level state into the media pipeline.

---

## 6. AssetStore and metadata flow

The app should be able to render the timeline from a local metadata database before a fresh network round trip completes.

```text
App launch
  -> read local asset metadata
  -> construct date sections
  -> timeline becomes usable
  -> perform network/sync refresh
  -> merge changes into local database
  -> emit narrow updates to visible sections/assets
```

Recommended cached metadata includes:

- asset ID
- taken/created date needed for timeline
- width / height / aspect ratio
- media type
- rating
- favorite if displayed
- thumbhash
- original MIME
- edit/current-version state
- content/cache revision fields

Large derived operations such as sorting/grouping should be performed in the data layer, not repeatedly in SwiftUI `body`.

### Timeline API strategy

Do not make Immich Internal `/timeline/*` endpoints a foundational dependency.

Preferred direction:

1. bootstrap with stable search/list functionality appropriate to the current server API;
2. group assets into the Otter timeline locally;
3. use the stable sync stream where the selected authentication method supports it; the API-key MVP instead uses overlapping metadata-search refresh and periodic reconciliation because Immich v3.1.0 rejects API keys for sync;
4. isolate any version-specific fallback in `ImmichCompatibility`.

---

## 7. Immich compatibility layer

The application targets arbitrary Immich servers. Compatibility therefore needs to be a named subsystem rather than ad-hoc `if version` checks in features.

```swift
protocol ImmichCompatibility: Sendable {
    var serverVersion: SemanticVersion { get }
    var capabilities: ServerCapabilities { get }

    func assetDescriptor(id: UUID) async throws -> MediaAssetDescriptor
    func searchAssets(_ request: AssetSearchRequest) async throws -> AssetPage
    func mediaRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest
}
```

Possible internal implementation:

```text
ImmichCompatibility
├── V2Adapter
├── V3Adapter
└── FutureAdapter
```

Do not create version-specific adapters prematurely if one implementation works. The architectural requirement is that version branching has a single home.

### Startup capability discovery

At connection/login time, record at least:

- server semantic version;
- authentication capability/permissions;
- whether rating can be mutated with the current credential;
- whether original download is permitted;
- observed behavior of thumbnail/preview/fullsize endpoints as they are used.

The current official API exposes `/server/version` as Stable. The client should query it instead of guessing compatibility from UI behavior.

---

## 8. Server media profile

Immich derivative configuration varies by server. Otter should learn observed media properties instead of assuming defaults.

```swift
struct ServerMediaProfile: Sendable {
    var thumbnail: RepresentationObservation?
    var preview: RepresentationObservation?
    var fullsize: RepresentationObservation?
}

struct RepresentationObservation: Sendable {
    let mimeType: String
    let maximumObservedDimension: Int
    let byteCount: Int?
}
```

When a derivative is downloaded successfully, inspect its actual header/properties with ImageIO and update the profile.

Example:

```text
requested timeline target: 360 px
observed thumbnail max dimension: 250 px
observed preview max dimension: 1440 px

=> planner should use preview/downsample for this target
```

This turns configuration variability into data rather than scattered hard-coded thresholds.

---

## 9. Networking

Use `URLSession` directly unless a concrete limitation justifies another dependency.

Recommended logical sessions:

### Metadata session

- search/sync/asset metadata/rating
- small responses
- responsive timeout policy
- should not be starved by bulk media transfer

### Media session

- thumbnail/preview/fullsize
- explicit request priority and cancellation
- custom byte cache is authoritative
- system URL cache should not create a second uncontrolled media cache

### Export/download session

- the Viewer-selected Original/Current rendition
- download-task/file-based behavior
- large payloads should flow to temporary files rather than whole-buffer `Data`

Credentials are injected by the auth provider and never become part of URLs or cache identity.

---

## 10. Concurrency ownership

Use Swift Concurrency for orchestration and actors for mutable shared state.

Good actor candidates:

- `RequestCoordinator`
- `WorkScheduler`
- cache metadata/index coordinator
- sync merge coordinator

Synchronous CPU-heavy image decoding should not run directly on the main actor or unconstrained Swift cooperative executor. Use a controlled dedicated decode executor/queue and return results asynchronously.

The number of simultaneous decode operations is intentionally small and benchmark-driven.

---

## 11. UI architecture

### Timeline

Start SwiftUI-first:

```text
ScrollView
  -> lazy sections
     -> lazy grid
        -> stable asset identity
```

The timeline view should own only narrow presentation state. It should not decode, resize, sort, group, or fetch directly in `body`.

If profiling later demonstrates that the required timeline performance cannot be reached with the chosen SwiftUI implementation, replacing the timeline container with `UICollectionView` is allowed without changing `AssetStore` or `MediaPipeline`.

### Fullscreen viewer

Use SwiftUI for the surrounding product shell, but UIKit is explicitly allowed for the media interaction surface if it provides cleaner control over:

- paging
- `UIScrollView` zoom/pan
- double-tap zoom
- gesture arbitration
- interactive dismissal
- image replacement while preserving viewport position

Native does not mean SwiftUI-only.

---

## 12. Export architecture

```swift
enum ExportVariant: Hashable, Sendable {
    case current
    case original
}
```

`AssetExporter` prepares a temporary file for the Viewer-selected rendition. `PhotosExporter` requests add-only authorization and creates the user-owned Photos asset. Success, failure, and cancellation clean the prepared file; a stale task cannot publish state for another Viewer item.

### Original contract

- preserve the original downloaded bytes whenever the server API provides the original file;
- do not silently re-encode;
- preserve metadata as provided by the source file.

### Current contract

- export the edited/current rendition when the connected server/version supports it;
- if not supported, fail with an explicit capability error;
- never silently export Original instead.

---

## 13. Observability boundary

Performance instrumentation belongs inside infrastructure rather than scattered debug prints in views.

Media operations should emit structured signposts for:

- request creation
- memory lookup
- disk lookup
- queue wait
- network start/end
- disk commit
- decode start/end
- first frame delivered
- final frame delivered
- cancellation and reason

Do not include user-sensitive photo metadata or authentication secrets.

See [Media Pipeline](media-pipeline.md) for the metric schema and budgets.

---

## 14. Architecture invariants

These rules are intended to remain true as the project grows:

1. UI never owns raw networking for media.
2. MediaPipeline never owns library/timeline membership.
3. AssetStore never decodes pixels.
4. Exported user files are not media-cache entries.
5. Cache identity includes server/account namespace.
6. Current and Original are explicit variants.
7. Metadata-only updates do not automatically invalidate media pixels.
8. Immich version/config differences are isolated behind compatibility/planning layers.
9. Internal Immich endpoints do not become foundational dependencies without an explicit decision record.
10. Main-thread image decode is a correctness/performance bug, not an optimization opportunity.
