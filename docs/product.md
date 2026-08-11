# Product Definition

## 1. Product statement

Otter is a **high-performance native iOS/iPadOS viewer for Immich**. The primary product goal is to make browsing a remote Immich photo library feel close to Apple Photos in responsiveness, direct manipulation, and visual continuity.

Otter treats Immich as a media/data backend rather than as a UI specification. It should use stable Immich capabilities while presenting an experience designed specifically for Apple platforms.

### Core verbs

> **Browse. View. Rate. Download.**

If a proposed feature does not materially improve one of these four workflows, it is outside the default product scope.

---

## 2. Primary experience

The critical path is:

```text
Launch
  -> timeline is immediately usable
  -> scroll through a large photo library without visible hitching
  -> tap an asset
  -> viewer appears immediately using the best already-available frame
  -> image quality upgrades progressively without interrupting interaction
  -> swipe to adjacent assets with no blank frame when prefetch succeeds
  -> pinch/double-tap to inspect detail
  -> rate or download explicitly
```

The product should optimize **perceived latency**, not merely raw network throughput. A cached lower-resolution frame shown immediately is preferable to waiting for a perfect image before presenting anything.

---

## 3. In scope

### Library browsing

- Chronological photo timeline.
- Date grouping.
- Large-library pagination/synchronization.
- Fast, direction-aware thumbnail prefetch.
- Smooth scrolling under tens of thousands of assets and above.

### Fullscreen viewer

- Immediate transition from timeline thumbnail to viewer.
- Horizontal paging.
- Pinch zoom.
- Double-tap zoom.
- Pan while zoomed.
- Interactive dismissal where it does not compromise gesture correctness.
- Progressive quality upgrades.
- Preservation of zoom/content position when a higher-resolution frame replaces the current frame.

### Rating

- Read Immich ratings including existing Rejected (`-1`) metadata.
- The editor writes only Unrated or 1–5 stars; Rejected remains displayable and can be changed, but is not a write choice.
- Favourite is a separate Boolean action and is not a rating value.
- Rating is a metadata mutation only; it MUST NOT invalidate photo pixel caches unless the server indicates media content itself changed.
- Filtering by rating is desirable after the core viewer is stable.

### Download / export

The user explicitly chooses the desired asset version in the Viewer:

- **Current Version** — the current edited rendition when supported.
- **Original** — the original imported file.

Pressing Download immediately saves that selected rendition to Photos with add-only permission. There is no second rendition/destination sheet in the core flow. The application MUST NOT silently substitute Original when Current Version is requested but unavailable, or Current when Original is unavailable. The UI explains that the selected rendition cannot be exported on that connection.

Downloads are user-initiated exports, not a synchronization system.

---

## 4. Current vs. Original semantics

Otter treats asset rendition as a first-class concept:

```swift
enum AssetVariant: Hashable, Sendable {
    case current
    case original
}
```

### Default viewer behavior

- Viewer defaults to **Current Version**.
- If no edit exists, Current may resolve to the same pixels as Original.
- The user can switch to **Original**.
- Current and Original are separate cacheable resources and MUST NOT share a render cache key unless they are proven byte/content equivalent.

Switching versions should preserve the current user context as much as possible. If Original is not ready, keep showing Current while the requested representation loads.

---

## 5. Explicit non-goals

The following are **not part of Otter's product scope** unless a future decision explicitly changes this document:

- Photo or video upload.
- Camera-roll backup.
- Automatic background backup.
- Bidirectional local library synchronization.
- Offline library management.
- Offline album pinning.
- Automatic original-file mirroring.
- Local photo editing.
- Immich administration.
- Library management.
- Trash/delete workflows.
- Face/person management.
- Duplicate management.
- Server job management.
- Reimplementation of every official Immich mobile feature.

Otter may later add albums, search, map browsing, video, Live Photo, RAW-specific presentation, HDR, or other viewer-oriented capabilities, but these remain secondary to timeline and still-image viewer quality.

---

## 6. Offline behavior

Otter makes **no offline availability guarantee**.

The local media cache exists only to improve browsing performance and may be evicted by Otter or the operating system.

When offline:

```text
render-memory hit -> show immediately
byte-disk-cache hit -> decode and show
cache miss -> show placeholder / unavailable state
```

No user-visible promise should imply that cached media is a durable local copy.

A file produced by an explicit Download action is different: once saved to Photos, it is user-owned persistent output and is no longer part of Otter's disposable media cache.

---

## 7. Server compatibility

Otter targets **arbitrary user-owned Immich servers**, not only the developer's test server.

The developer's server may be configured to improve testing, but the released client MUST NOT depend on a particular thumbnail size, preview size, output format, fullsize configuration, or administrator-only setting.

The client should discover or infer server media behavior at runtime, including:

- Immich server version.
- API capability/permission availability.
- Actual thumbnail dimensions and format.
- Actual preview dimensions and format.
- Fullsize availability/redirect behavior.
- Original-download permission.
- Current-version/edited rendition behavior.

The client MUST prefer stable public Immich APIs. Internal endpoints must not become foundational dependencies. In particular, the current `/timeline/*` APIs are marked Internal by Immich; Otter should build its own timeline grouping on stable search/sync data rather than coupling its core UX to those endpoints.

The current Immich `/server/version`, asset thumbnail/original endpoints, and sync stream are documented as Stable as of 2026-08-10. However, Immich v3.1.0 explicitly rejects API-key authentication for the sync stream. The API-key MVP therefore uses stable metadata search with overlap polling and periodic reconciliation, and does not claim real-time sync. API status is not permanent; compatibility code must remain isolated behind the compatibility boundary.

---

## 8. Authentication and permissions

Use the minimum permissions required for the viewer workflow.

Expected capability categories include:

- asset read/view
- asset download
- rating/metadata update as required by the current Immich API
- sync/read capabilities required for the metadata store

Otter MUST NOT request upload, delete, administrative, library-management, or unrelated privileges merely for convenience.

Credentials belong in Keychain and MUST NOT appear in URLs, cache keys, application logs, crash diagnostics, or analytics events.

---

## 9. Cache product behavior

Default media disk-cache limit:

> **2 GiB**

The user can change it in Settings. Initial choices should remain explicit and predictable, for example:

- 512 MiB
- 1 GiB
- 2 GiB
- 5 GiB
- 10 GiB

The limit is global across configured servers/accounts, while cache identity remains isolated by server and user namespace.

Cache settings should describe the feature as a performance cache, not offline storage.

---

## 10. Platform scope

Current product target:

- **iPhone — supported**
- **iPad — supported**
- Minimum version: **iOS/iPadOS 18+**

macOS is not part of the current release target. The architecture should avoid gratuitous platform coupling where easy to avoid, but macOS compatibility is not allowed to slow or compromise the first iOS/iPadOS viewer.

---

## 11. Media scope by phase

### Initial release

- JPEG
- HEIC/HEIF where supported by system decoders
- PNG
- server-generated WebP derivatives where supported
- SDR / Display P3 presentation

### Later phases

- HDR / gain-map-aware presentation
- video
- Live Photo
- RAW-specific behavior
- advanced deep zoom / tiled rendering

HDR is intentionally not a release blocker. Server-generated preview derivatives may not preserve the complete HDR semantics of an original HEIC/HEIF asset, so a future HDR path may need original-file retrieval and a separate decode/presentation policy.

---

## 12. UX principles

### Image first

Photos remain the primary visual hierarchy. Controls should be quiet and transient.

### Native interaction grammar

Use Apple-platform conventions for scrolling, paging, zooming, gestures, menus, sheets, sharing, accessibility, haptics, and system integration. "Native" means using the platform interaction model, not requiring 100% SwiftUI.

SwiftUI should be preferred for normal product UI. UIKit is acceptable where it earns its keep, especially for a complex high-performance media viewer.

### No blank-state regressions during progressive loading

If a lower-quality frame is already visible, higher-quality work must not replace it with a loading spinner or blank surface.

### No hidden work that fights the user's current gesture

High-resolution replacement, prefetch, cache maintenance, and speculative decoding should yield to the currently visible or interactive asset.

---

## 13. Success criteria

Otter succeeds when users notice the photos rather than the client.

The strongest indicators are:

- Timeline remains responsive during aggressive scrolling.
- Opening a cached asset appears effectively immediate.
- Viewer paging normally produces no blank frame.
- High-resolution upgrades do not disturb zoom/pan state.
- Network degradation produces graceful quality degradation rather than UI stalls.
- Memory returns toward a stable envelope after extended browsing.
- Rating and download remain explicit, predictable, and semantically correct.

Detailed performance budgets live in [Media Pipeline](media-pipeline.md).
