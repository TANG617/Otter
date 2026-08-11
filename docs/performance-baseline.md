# Performance Baseline

Captured on 10 August 2026 with the Debug simulator build, iPhone 17 Pro / iOS 27.0, Xcode 27.0 beta, and a deterministic 100,000-asset fixture. These are diagnostic simulator figures, not physical-device release claims.

## Focused timeline scroll trace

Flow: settle the 100k timeline, perform three 90% upward swipes, and wait for visible progressive rendering to settle.

| Measurement | Result |
|---|---:|
| ETTrace window | 61.988 s |
| Main-thread idle samples | 57.738 s |
| Main-thread active samples | 4.210 s |
| Unattributed samples | 0.041 s |
| Largest Otter-owned self sample bucket | 5.714 ms, `FixtureRenderKey.isEqual` |
| Next Otter-owned self sample bucket | 5.322 ms, media-request equality |

Otter and its debug dynamic library were UUID-matched to the captured dSYM. The trace reported no missing-library samples. ETTrace itself and iOS 27 beta system frameworks were partially unsymbolicated; those system buckets are not used for Otter conclusions. Xcode UI automation activates accessibility work during every snapshot, so SwiftUI/UIAccessibility inclusive costs in this run are measurement overhead as well as app work.

The trace did not reveal a sustained Otter-owned main-thread hotspot. This is consistent with paged fixture generation, incremental timeline insertion, bounded/cancellable fixture decoding, and off-main media work. It is not evidence of a physical-device frame rate.

Ignored local artifact:

```text
.codex-artifacts/performance/ettrace-run/run-20260810-scroll100k/output_259.json
```

## Structural timeline regression baseline

Captured on 11 August 2026 with deterministic operation counters rather than wall-clock assertions:

| Scenario | Incremental operations | Full section rebuild delta | Fallback rebuilds |
|---|---:|---:|---:|
| One metadata update in a 10,000-asset window, repeated for Years/Months/All | 3 metadata patches | 0 | 0 |
| 10,000 assets loaded as 100 ordered pages | 99 page appends | 0 after initial window | 0 |
| Deliberately out-of-order page | 0 normal appends | 1 | 1 |
| Capture-date movement | 0 metadata patches | 1 | n/a |

These counters guard the algorithmic path: rating/Favourite updates do not rebuild the loaded library or advance `windowRevision`, and normal pagination processes only incoming assets plus the trailing section. They do not replace device profiling.

## Viewer release memgraph

Flow: after the same timeline scroll, open one Viewer item, allow its media to settle, close Viewer, wait one second, then capture the running process.

| Measurement | Result |
|---|---:|
| Physical footprint at capture | 259.8 MiB |
| Peak physical footprint | 314.3 MiB |
| Malloc graph | 224,848 nodes / 77,129 KiB |
| Leak candidates | 40 / 1,312 bytes |
| Otter-owned leaked types or ownership paths | 0 |

The 40 leak candidates were 38 anonymous 32-byte malloc-zone nodes and two SwiftUI `MaterialLuminanceAggregator` array-storage nodes. No Otter type appeared in the leak list, grouped tree, or ownership paths. This is a clean app-owned result for this one simulator flow; it does not prove that all flows are leak-free.

Ignored local artifacts:

```text
.codex-artifacts/performance/memgraph-100k/com.tang617.otter-87022-20260810-172612.memgraph
.codex-artifacts/performance/memgraph-100k/leak-summary.md
```

## Implemented performance guards

- Metadata is paged and reconciled through GRDB; the UI does not materialize a 100k library at launch.
- Timeline insertion and grouping are incremental instead of repeatedly sorting the full loaded library.
- Viewer filmstrip requests use only Current timeline thumbnails, a 128–192 pixel demand, lazy cell cancellation, and at most eight proactive neighbor/prefetch requests.
- Media byte work is coalesced; render cache identity includes account, variant, revision, purpose, and pixel bucket.
- Interactive requests suppress queued speculative work; per-lane concurrency is bounded and queued work is cancellable.
- Missing or corrupt derivatives fall through to the next legal representation.
- Timeline, Viewer, and zoom decode ceilings are 512, 3072, and 4096 pixels respectively; a maximum zoom RGBA surface is approximately 64 MiB.
- Disk-cache clear records pending deletion for active leases and prevents released work from silently repopulating signed-out account data.

## Remaining release gates

1. Run the same flows with Time Profiler, Animation Hitches, Allocations, and Leaks on representative physical iPhone and iPad hardware.
2. Repeat performance, memory, and broader iPad tests on an iOS 18.x runtime; GitHub CI already covers the generic build, unit suite, and one key iPhone UI smoke on iOS 18.5, while this machine currently has only iOS 27.0.
3. Exercise 12 MP/48 MP JPEG, PNG, HEIF, WebP, corrupt payloads, network loss, 429, and constrained-memory paths on device.
4. Record cold and warm live-server runs on a stable LAN without UI-automation accessibility sampling.
