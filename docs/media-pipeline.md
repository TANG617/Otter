# Media Pipeline

## 1. Purpose

`MediaPipeline` is the performance-critical core of Otter. Its responsibility is not simply to download an image. It must continuously choose the cheapest representation that satisfies the user's current visual demand while preserving smooth interaction.

The pipeline combines:

```text
resource planning
+ request coalescing
+ priority scheduling
+ cancellation
+ layered caching
+ controlled decode/downsample
+ progressive delivery
+ prefetch
+ observability
```

The central product rule is:

> **Never make the user wait for perfect pixels when useful pixels are already available.**

---

## 2. Non-responsibilities

`MediaPipeline` MUST NOT:

- decide which assets belong in the timeline;
- synchronize the Immich asset catalog;
- own rating state;
- implement uploader or backup behavior;
- promise offline availability;
- perform explicit user export as a side effect of cache fetch;
- expose Immich DTOs directly to UI;
- perform heavy image work from a SwiftUI `body`.

Those responsibilities belong to `AssetStore`, `AssetExporter`, and presentation layers.

---

## 3. Remote representation vs. rendered representation

A single server derivative can satisfy multiple display sizes. The pipeline therefore MUST distinguish compressed remote bytes from decoded render surfaces.

### Remote representation

```swift
enum RemoteRepresentation: String, Hashable, Sendable {
    case thumbnail
    case preview
    case fullsize
    case original
}
```

Immich currently exposes these media-size concepts for asset viewing. Exact server dimensions and formats are configurable and MUST NOT be hard-coded.

### Render specification

```swift
struct RenderSpecification: Hashable, Sendable {
    let pixelBucket: Int
    let dynamicRange: DynamicRangePolicy
    let contentMode: MediaContentMode
}
```

Example:

```text
one preview JPEG/WebP on disk
    -> 384 px render for a grid cell
    -> 1536 px render for a large card
    -> 2048 px render for fullscreen
```

Network work may be shared; decoded bitmap work is keyed by target demand.

---

## 4. Cache identity

### Byte cache key

```swift
struct ByteCacheKey: Hashable, Sendable {
    let accountNamespace: UUID
    let assetID: UUID
    let variant: AssetVariant
    let representation: RemoteRepresentation
    let contentRevision: String
}
```

`accountNamespace` MUST uniquely include server and user identity. Two different Immich accounts must never share media-cache identity even if asset UUIDs collide.

### Render cache key

```swift
struct RenderCacheKey: Hashable, Sendable {
    let byteKey: ByteCacheKey
    let specification: RenderSpecification
    let transformVersion: Int
}
```

The same byte representation decoded to different pixel buckets produces different render entries.

### Content revision rules

Cache invalidation MUST track pixel content, not generic metadata modification time.

Metadata-only changes such as rating SHOULD NOT invalidate thumbnail/preview/original caches.

Preferred revision inputs:

- thumbnail/preview/fullsize: server-provided derivative/content revision signal when available; a thumbnail cache-busting value such as `thumbhash` is a useful input where appropriate;
- original: checksum/content hash;
- edited/current rendition: a dedicated edit/content revision if the server exposes one;
- fallback: conservative versioning isolated in the Immich compatibility layer.

Do not globally use a generic `updatedAt` field when it can change for metadata-only edits.

---

## 5. Public API

The pipeline should support an immediate memory peek and an asynchronous progressive stream.

```swift
protocol MediaPipelineProtocol: Sendable {
    func peek(_ request: MediaRequest) -> MediaFrame?

    func frames(
        for request: MediaRequest
    ) -> AsyncThrowingStream<MediaFrame, Error>

    func prefetch(
        _ requests: [MediaRequest]
    ) -> PrefetchToken

    func invalidate(assetID: UUID) async
    func clearMemory() async
    func clearDisk() async throws
}
```

### Request model

```swift
struct MediaRequest: Hashable, Sendable {
    let asset: MediaAssetDescriptor
    let variant: AssetVariant
    let purpose: MediaPurpose
    let viewport: PixelSize
    let displayScale: Double
    let zoomScale: Double
    let qualityPolicy: QualityPolicy
    let dynamicRange: DynamicRangePolicy
    let priority: MediaPriority
}

enum MediaPurpose: Hashable, Sendable {
    case timeline
    case viewer
    case zoom
}

enum QualityPolicy: Hashable, Sendable {
    case fast
    case balanced
    case maximum
}

enum MediaPriority: Int, Comparable, Sendable {
    case speculative = 10
    case prefetch = 30
    case neighbor = 60
    case visible = 80
    case interactive = 100
}
```

### Progressive frame

```swift
struct MediaFrame: Sendable {
    let surface: RenderSurface
    let quality: MediaQuality
    let source: MediaSource
    let isFinalForCurrentDemand: Bool
}

enum MediaQuality: Hashable, Sendable {
    case placeholder
    case thumbnail
    case preview
    case fullsize
    case originalDownsample
}

enum MediaSource: Hashable, Sendable {
    case generatedPlaceholder
    case memoryCache
    case diskCache
    case network
}
```

A request may yield:

```text
ThumbHash placeholder
    -> cached thumbnail
    -> preview
    -> high-resolution frame
```

The UI keeps showing the best delivered frame until a better one is ready.

---

## 6. Representation Planner

`RepresentationPlanner` translates viewport demand into a sequence of candidate resources.

It MUST NOT assume that server `thumbnail` or `preview` names imply fixed pixel dimensions.

### Initial planning policy

| Context | First useful frame | Normal target | Possible upgrade |
|---|---|---|---|
| 4–6 column timeline | ThumbHash / memory frame | thumbnail | preview if thumbnail is undersized |
| larger grid | thumbnail | preview downsample | normally none |
| viewer open | existing timeline frame | preview | fullsize/original if needed |
| viewer N±1 | thumbnail | preview | no eager original |
| viewer N±2 | ThumbHash | thumbnail | none |
| zoom | current frame | representation satisfying pixel demand | fullsize/original |

### Server profile feedback

The pipeline should learn real derivative characteristics:

```swift
struct RepresentationObservation: Sendable {
    let mimeType: String
    let maxDimension: Int
    let byteCount: Int?
}
```

After first successful decode, inspect actual pixel dimensions and MIME. Feed observations into future planning.

Example:

```text
cell needs: 360 physical pixels
observed thumbnail: 250 px
observed preview: 1440 px

=> request preview and downsample locally
```

### Demand calculation

For fullscreen/zoom, calculate required physical pixels from the actual displayed image region:

```text
required display pixels
= displayed logical size
× display scale
× zoom scale
× overscan factor
```

Use a modest overscan factor such as 1.1–1.2 to avoid immediate re-upgrade around thresholds.

### Coverage and hysteresis

```text
coverage = available pixels / required pixels
```

Suggested behavior:

```text
coverage >= 1.0  -> current render is sufficient
coverage < 0.85   -> plan next representation
0.85...1.0        -> hysteresis zone; do not thrash
```

Within one viewer lifecycle, quality normally moves in one direction:

```text
thumbnail -> preview -> fullsize -> originalDownsample
```

Do not repeatedly downgrade and re-upgrade because the user's pinch scale moves around a boundary.

---

## 7. Pixel buckets

Arbitrary target sizes cause cache fragmentation and repeated decode during layout changes.

Use discrete pixel buckets, for example:

```swift
let pixelBuckets = [
    128,
    192,
    256,
    384,
    512,
    768,
    1024,
    1536,
    2048,
    3072,
    4096,
    6144
]
```

Examples:

```text
347 px demand  -> 384 bucket
401 px demand  -> 512 bucket
1830 px demand -> 2048 bucket
2460 px demand -> 3072 bucket
```

The exact bucket list is tunable. It should be benchmarked rather than proliferated.

Typical first-release use:

- timeline: 256 / 384 / 512;
- fullscreen: 2048 / 3072;
- zoom: 4096;
- 6144: exceptional current-asset use only if memory allows.

---

## 8. Request lifecycle

A normal request follows this sequence:

```text
1. produce cheap placeholder when available
2. check Render Memory Cache
3. check Byte Disk Cache
4. join an existing in-flight byte request if present
5. otherwise enter WorkScheduler
6. download to memory or temporary file according to expected size
7. validate HTTP response and media header
8. commit compressed bytes atomically to Byte Disk Cache
9. join/create render decode work
10. downsample/orientation-normalize on controlled decode queue
11. insert Render Surface into Memory Cache
12. deliver MediaFrame
13. if demand is still unmet, continue to the next planned representation
```

No later stage may blank a frame already delivered by an earlier stage.

---

## 9. Two-level request coalescing

One in-flight dictionary is insufficient.

### Byte-level coalescing

These requests should share one network transfer:

```text
Asset A / preview / target 2048
Asset A / preview / target 3072
```

Both consume the same `ByteCacheKey`.

### Render-level coalescing

These requests should also share decode work:

```text
Asset A / preview / target 2048
Asset A / preview / target 2048
```

Both consume one `RenderCacheKey` decode.

Recommended coordinator:

```swift
actor RequestCoordinator {
    private var byteRequests: [ByteCacheKey: SharedByteRequest] = [:]
    private var renderRequests: [RenderCacheKey: SharedRenderRequest] = [:]
}
```

---

## 10. Consumer leases

Shared work must track consumers explicitly.

```swift
struct ConsumerID: Hashable, Sendable {
    let id: UUID
}

struct SharedRequestState<Key: Hashable & Sendable>: Sendable {
    let key: Key
    var consumers: Set<ConsumerID>
    var effectivePriority: MediaPriority
}
```

Example:

```text
Timeline cell ─┐
Viewer         ─┼── shared preview request
Prefetcher     ─┘
```

If the cell disappears, only its lease is released. The underlying request is cancelled **only when no consumers remain** or when the scheduler explicitly evicts speculative work.

This prevents one disappearing view from cancelling media another visible view still needs.

---

## 11. Priority promotion

A prefetched request can become visible before it finishes.

Example:

```text
N+1 preview is 40% downloaded at .neighbor
user swipes to N+1
```

Correct behavior:

```text
reuse same transfer
.neighbor -> .interactive
promote pending decode priority
preserve downloaded progress
```

Do not cancel and restart merely because purpose/priority changed.

The scheduler should maintain its own ordering even if URLSession task priority is also used as a hint.

---

## 12. WorkScheduler

The app MUST NOT create unlimited independent tasks for every visible/prefetched cell.

Start with conservative concurrency lanes and tune with measurements:

| Work lane | Initial concurrency |
|---|---:|
| metadata API | 2–4 |
| visible thumbnails | 4 |
| previews | 2 |
| fullsize | 1 |
| explicit original export | 1 |
| disk IO | 2 |
| image decode | 1 |
| ThumbHash decode | 1 |

These are starting values, not permanent product guarantees.

### Global ordering

```text
interactive
> visible
> neighbor
> prefetch
> speculative
```

When interactive work arrives:

- stop dispatching new speculative work;
- cancel queued distant prefetch that has not started;
- promote relevant N±1 work;
- do not let original/fullsize speculation block current preview;
- keep nearly-complete useful transfers when cancellation would waste more than it saves.

The last rule should be data-driven. The scheduler may consider transfer progress, expected remaining bytes, and current contention.

---

## 13. Networking sessions

Use separate logical `URLSession` configurations so metadata cannot be starved by image transfer.

### Metadata session

Owns:

- search/list/bootstrap
- sync
- asset metadata
- rating update
- capability/version probes

### Media session

Owns:

- thumbnail
- preview
- fullsize

Properties:

- explicit cancellation;
- priority hints;
- custom byte cache is authoritative;
- avoid a second uncontrolled system media cache.

### Export/download session

Owns user-requested Current/Original downloads.

Large downloads should use file/download semantics rather than first buffering the entire resource in memory.

---

## 14. Transport and file handling

### Small derivatives

A small thumbnail may safely use an in-memory `Data` response if profiling shows it is efficient.

### Preview/fullsize/original

Prefer file-backed flow:

```text
URLSession download
 -> temporary file
 -> validate
 -> atomic move into cache (if cacheable)
 -> CGImageSource from file URL
```

Avoid this for large assets:

```swift
let data = try await fetchEverything()
let image = UIImage(data: data)
```

A 48 MP 8064×6048 image expanded to 8-bit RGBA is roughly 186 MiB before counting compressed input and additional rendering overhead. Original bytes should therefore remain file-backed until a size-bounded render is requested.

---

## 15. Decode pipeline

### First-release cross-cutting decoder

Use ImageIO / `CGImageSource` as the baseline because it supports:

- file-backed sources;
- metadata/header inspection;
- target-size thumbnails/downsampling;
- orientation transforms;
- controlled decode timing.

Conceptual implementation:

```swift
protocol MediaDecoding: Sendable {
    func decode(
        fileURL: URL,
        maxPixelSize: Int
    ) async throws -> RenderSurface
}
```

A typical ImageIO path uses:

- source caching disabled initially;
- `CGImageSourceCreateThumbnailFromImageAlways`;
- `CGImageSourceCreateThumbnailWithTransform`;
- `CGImageSourceThumbnailMaxPixelSize`;
- immediate decode/cache when creating the final thumbnail so first draw does not unexpectedly pay the decode cost.

### Dedicated decode executor/queue

Image decoding is synchronous CPU work under the hood. Do not perform it on `MainActor` and do not assume spawning many Swift `Task`s makes it cheap.

Start with a dedicated serial decode queue/executor. Benchmark concurrency 2 only after real traces demonstrate an improvement without harmful memory/CPU contention.

### Presentation bridge

The pipeline should preferably cache an immutable `CGImage`-backed `RenderSurface`. UIKit/SwiftUI conversion happens at the presentation edge.

---

## 16. ThumbHash placeholder

Where Immich metadata exposes a `thumbhash`, use it as a cheap placeholder source.

Progressive experience:

```text
0 ms    generated ThumbHash
~10 ms  render-memory hit if present
~tens   disk cached thumbnail decode
~100+   network thumbnail/preview depending on network
```

A placeholder is not a substitute for prefetch. Its job is to preserve visual continuity instead of showing empty gray boxes.

ThumbHash decoding should be cached and low priority.

---

## 17. Render Memory Cache

The memory cache stores only display-ready, size-bounded render surfaces.

It MUST NOT retain:

- original compressed `Data`;
- unrestricted full-resolution decoded images;
- arbitrary duplicate pixel sizes;
- a second unbounded copy of every disk-cached image.

Use `NSCache` or an equivalent cost-aware cache and set cost from decoded bytes, for example:

```text
bytesPerRow × pixelHeight
```

### Starting budget

A reasonable first profiling target is approximately:

```text
~128 MiB decoded-image soft limit
```

This is not a hard product constant. Device memory class and observed pressure may justify tuning.

Example costs:

```text
384×384 RGBA    ~0.56 MiB
3072×2304 RGBA  ~27 MiB
```

This is why five neighboring 3K viewer bitmaps are already expensive.

### Pinning

The current visible viewer frame may be pinned temporarily.

N±1 can have elevated retention priority.

Distant timeline/prefetch surfaces should be evictable first.

### Memory pressure

On memory warning/pressure:

1. preserve only the minimum currently visible surface(s);
2. evict fullsize/large neighbor renders;
3. clear speculative renders;
4. allow byte disk cache to remain.

---

## 18. Byte Disk Cache

Store compressed server responses as files, not SQLite BLOBs.

Suggested location:

```text
Library/Caches/OtterMedia/
└── <account-namespace>/
    ├── thumbnail/
    ├── preview/
    ├── fullsize/
    └── temp/
```

Use a hash of the canonical `ByteCacheKey` as filename. Shard large directories if needed:

```text
ab/cd/abcdef...media
```

### Cache index

SQLite schema concept:

```sql
CREATE TABLE media_cache_entry (
    cache_key TEXT PRIMARY KEY,
    asset_id TEXT NOT NULL,
    representation INTEGER NOT NULL,
    file_path TEXT NOT NULL,
    byte_count INTEGER NOT NULL,
    content_type TEXT,
    pixel_width INTEGER,
    pixel_height INTEGER,
    created_at REAL NOT NULL,
    last_access_at REAL NOT NULL
);
```

### Atomic commit

```text
download temp file
 -> validate HTTP/media
 -> close file
 -> atomic move to final cache path
 -> commit/update index
```

A crash during transfer may leave removable temp files but must not create a valid index entry pointing at partial media.

### LRU

Default total budget: **2 GiB**, user configurable.

Use soft category targets rather than hard partitions, for example:

```text
thumbnail ~15%
preview   ~70%
fullsize  ~15%
```

Originals fetched solely for explicit export should not automatically become long-lived viewer cache entries.

When exceeding the limit, evict to a lower watermark rather than exactly back to the ceiling:

```text
2.0 GiB exceeded
 -> clean to ~1.6 GiB
```

This avoids eviction on every subsequent file.

### Access-time batching

Do not update SQLite on every cache hit.

```text
hit
 -> add key to in-memory touch set
 -> batch last_access_at updates periodically
```

This reduces tiny writes during fast scrolling.

---

## 19. Timeline prefetch

Prefetch should be direction- and velocity-aware.

Example starting policy:

### Slow/stationary

```text
forward 12–20 assets
backward 4–8 assets
```

### Fast directional scroll

```text
forward 30–50 thumbnail candidates
backward 2–4
no preview speculation
```

### Very fast flick

Keep only:

```text
visible
+ near-future thumbnail work
```

Cancel/demote:

```text
distant thumbnails
preview speculation
fullsize speculation
```

A high prefetch cancellation rate is not inherently bad. It can indicate that the client correctly stops work when the user's intent changes.

---

## 20. Fullscreen viewer prefetch

For current asset `N`:

```text
N     -> preview, interactive; high-resolution eligible after demand/settle
N±1   -> preview, neighbor
N±2   -> thumbnail, prefetch
farther -> ThumbHash/metadata only
```

During a paging gesture, promote based on direction before the transition completes.

Possible starting thresholds:

```text
drag progress > 0.15 -> promote target N±1
near commit           -> begin N±2 thumbnail prep
cancelled page        -> restore priorities
```

Thresholds are UX tuning parameters, not API contracts.

---

## 21. High-resolution replacement and gesture safety

High-resolution frames must not disturb active manipulation.

Viewer interaction state should be explicit:

```swift
enum ViewerInteractionState: Sendable {
    case idle
    case paging
    case zooming
    case panning
    case dismissing
}
```

Suggested policy:

| State | Higher-quality frame arrives |
|---|---|
| idle | replace seamlessly |
| paging | stage until page settles if needed |
| zooming | stage until gesture end unless replacement is proven stable |
| panning | preserve photo-space anchor and content offset |
| dismissing | do not start/continue expensive upgrade |

When replacing pixels during zoom, preserve:

- zoom scale;
- visible image-space center/anchor;
- content offset;
- orientation/crop mapping.

A sharper image that visibly jumps is a UX regression.

---

## 22. Current vs. Original switching

Current and Original are separate media trees.

```text
Asset
├── current
│   ├── thumbnail
│   ├── preview
│   └── fullsize/current rendition
└── original
    └── original file -> local downsampled renders
```

When the user switches to Original:

1. keep Current displayed;
2. look for a suitable Original render in memory;
3. if absent, reuse any cached Original bytes;
4. otherwise request Original at interactive priority;
5. decode only the pixel bucket required by current viewport/zoom;
6. replace while preserving viewer geometry.

If the user switches back to Current before Original finishes:

- immediately restore Current from retained/cached frame;
- release the interactive consumer lease on Original;
- if another consumer still needs Original, keep the transfer;
- if no consumer remains, either cancel or demote based on transfer progress and scheduler policy;
- never treat Current and Original as the same `RenderCacheKey` by default.

---

## 23. Deep zoom boundary

First release should not attempt a full tiled-image architecture.

Without a stable region/tile service, decoding arbitrary areas of huge JPEG/HEIC originals may still incur large decode costs.

Initial policy:

```text
normal fullscreen -> up to ~3072 px bucket
zoom upgrade      -> ~4096 px bucket
exceptional current asset -> 6144 only after measurement
```

Limit maximum zoom based on available rendered detail rather than silently decoding unrestricted full-resolution bitmaps.

True deep zoom can later be designed around server tiles, local pyramids, or format-specific region decoding.

---

## 24. HDR boundary

First release supports SDR / Display P3 and does not require full HDR gain-map fidelity.

Timeline should remain SDR for predictable decode/render cost.

Future HDR fullscreen behavior may require:

- identifying HDR-capable source assets;
- retrieving Original HEIC/HEIF rather than assuming a server JPEG/WebP derivative preserves HDR semantics;
- an HDR-aware decoder/presentation path;
- separate memory budgets and performance tests.

HDR work MUST NOT block the first timeline/viewer release.

---

## 25. Error handling

Suggested behavior matrix:

| Condition | Pipeline behavior |
|---|---|
| 401/auth invalid | transition to global auth-invalid state; no retry loop |
| 403 | capability/permission error; do not attempt unsafe workaround |
| missing thumbnail | short negative cache; try a valid alternative representation if policy allows |
| missing preview | keep lower-quality frame; explicit retry path |
| 429 | respect server retry semantics/Retry-After |
| transient 5xx | bounded retry for visible work only |
| timeout | visible request may retry once; distant prefetch normally does not |
| cancellation | normal control flow, not user-facing error |
| corrupted disk cache | delete entry and fetch once from network |
| repeated decode failure | mark representation failed for session/short TTL and preserve placeholder/lower frame |
| offline | memory -> disk -> placeholder/unavailable; no per-cell alerts |

### Negative cache

A server may temporarily lack a generated derivative. Cache a missing-derivative result for a short TTL (tens of seconds, not hours) to prevent repeated hammering while allowing background generation to complete.

---

## 26. Cancellation rules

Cancellation is a core feature, not cleanup.

A request should stop when:

- all consumer leases are gone and the scheduler decides the remaining work is not worth retaining;
- distant prefetch becomes irrelevant;
- the asset/version is invalidated;
- the app enters a state where expensive speculative work is inappropriate.

Cancellation should propagate through:

```text
UI consumer
 -> coordinator lease
 -> scheduler queued work
 -> URLSession task
 -> pending decode
```

Already-completed cached bytes remain useful and should not be deleted merely because a consumer cancelled.

---

## 27. Observability

Instrument from day one with `os_signpost` / structured metrics.

Events:

```text
request_created
placeholder_delivered
memory_lookup_begin/end
disk_lookup_begin/end
queue_enter/leave
network_begin/first_byte/end
disk_commit_begin/end
decode_begin/end
frame_delivered
request_promoted
request_cancelled
eviction
```

Useful dimensions:

- hashed/truncated non-sensitive asset identifier;
- representation;
- variant;
- pixel bucket;
- priority;
- source;
- cache hit/miss;
- queue wait;
- bytes transferred;
- decode pixel count;
- estimated decoded cost;
- time to first useful frame;
- time to final frame for current demand;
- cancellation reason.

Never log:

- auth token/API key;
- original filename unless explicitly needed for local debug and redacted in production;
- precise photo location;
- user email;
- full server credentials.

---

## 28. Performance budgets

These are engineering targets to validate and revise with real devices.

| Metric | Initial target |
|---|---:|
| render-memory lookup | < 1 ms |
| main-thread image assignment work | < 2 ms |
| main-thread image decoding | 0 |
| cached timeline image disk-read+decode p95 | < 60 ms |
| cached viewer preview disk-read+decode p95 | < 120 ms |
| simultaneous network fetches for same ByteCacheKey | exactly 1 |
| blank viewer frame after successful neighbor prefetch | 0 |
| cancelled work that proceeds into expensive decode | near 0 |
| memory after long browsing session | returns toward stable envelope |

Display frame budgets:

```text
60 Hz  -> 16.67 ms
120 Hz -> 8.33 ms
```

A 30 ms decode is acceptable off the UI thread but is an obvious hitch if first paid during a main-thread draw.

---

## 29. Test matrix

### Library scale

- 1,000 assets
- 10,000 assets
- 50,000 assets
- 100,000 assets

### Media

- JPEG
- HEIC/HEIF
- PNG with alpha
- WebP derivatives
- portrait / landscape / panorama
- 12 MP / 24 MP / 48 MP originals
- corrupted image
- missing derivative
- edited/current asset

### Network

- low-latency LAN
- normal WAN
- high latency
- packet loss
- offline
- Wi-Fi to cellular transition
- connectivity loss during transfer

### User stress

- high-speed timeline scrolling for 60 seconds;
- repeated direction reversal;
- open viewer and swipe hundreds of images;
- rapid left/right reversal;
- pinch/zoom while high-resolution arrives;
- switch Current/Original repeatedly;
- background/foreground;
- memory pressure;
- clear cache while idle;
- rating mutations while viewing;
- server derivative revision while cached.

---

## 30. Required unit/integration tests

At minimum:

1. Same `ByteCacheKey` creates one network request.
2. Different render targets reuse one byte representation.
3. Same `RenderCacheKey` creates one decode task.
4. One consumer cancelling does not cancel work required by another.
5. Final consumer release allows cancellation.
6. Prefetch request can be promoted to interactive without restart.
7. Rating metadata update does not invalidate media content key.
8. Derivative revision change invalidates only affected derivative variants.
9. Original checksum/content revision change invalidates original identity.
10. Corrupted cache file is removed and fetched again once.
11. LRU eviction respects byte budget and lower watermark.
12. Active/pinned files are not evicted underneath consumers.
13. Interrupted atomic cache write cannot become a valid entry.
14. Original 48 MP input is decoded only to requested bounded bucket.
15. No decode path is executed on `MainActor`.
16. High-resolution replacement preserves viewer geometry.
17. Current and Original do not accidentally alias cache keys.
18. Offline cache miss does not produce repeated per-cell retry storms.

---

## 31. Implementation phases

### Phase 0 — measurement harness

Build before polished UI:

- fake media transport;
- deterministic local image fixtures;
- disk cache;
- signposts/metrics;
- latency/failure simulation.

### Phase 1 — timeline pipeline

- ThumbHash placeholder;
- thumbnail representation;
- render memory cache;
- byte disk cache;
- request coalescing;
- cancellation;
- timeline prefetch.

Exit criterion: aggressive scrolling is stable on target devices.

### Phase 2 — fullscreen viewer

- preview representation;
- N±1 prefetch;
- progressive replacement;
- viewer pinning;
- clean paging/zoom interaction.

### Phase 3 — zoom / high resolution

- coverage-based quality planning;
- fullsize behavior;
- file-backed Original retrieval;
- 4096-class local downsample;
- geometry-preserving high-resolution swap.

### Phase 4 — explicit export

Implement separately through `AssetExporter`:

- use the Current or Original selection already visible in Viewer;
- save directly to Photos with add-only authorization;
- never substitute the other rendition;
- progress/error state.

### Later

- HDR;
- video pipeline;
- Live Photo;
- RAW-specific paths;
- tiled/deep zoom if product demand justifies it.

---

## 32. Non-negotiable pipeline rules

1. Timeline MUST NOT automatically download Original.
2. Image decoding MUST NOT happen on the main thread.
3. Remote byte identity and decoded render identity MUST be separate.
4. Metadata-only rating or Favourite changes MUST NOT invalidate photo pixels.
5. Prefetch MUST support cancellation, promotion, and request sharing.
6. Large media MUST remain file-backed until a bounded decode is requested.
7. Cells MUST NOT create an unbounded set of independent network/decode tasks.
8. The custom byte cache MUST remain the authoritative media disk cache.
9. Viewer MUST preserve a lower-quality visible frame while upgrading.
10. Current and Original MUST remain explicit variants.
11. Server derivative sizes/formats MUST be observed/adapted, not assumed.
12. Performance conclusions MUST be supported by Instruments/metrics.
