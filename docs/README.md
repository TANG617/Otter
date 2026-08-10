# Otter Documentation

Otter is a high-performance, native photo viewer for Immich on Apple platforms. Its purpose is deliberately narrow: make browsing a remote Immich library feel as immediate, fluid, and natural as browsing Apple Photos.

Otter is **not** a replacement implementation of the entire Immich mobile app. The product is centered on four verbs:

> **Browse. View. Rate. Download.**

Uploader, backup, automatic local-library synchronization, and offline-library management are explicitly out of scope.

## Product principles

1. **Viewer first.** Timeline browsing and the fullscreen viewer are the product.
2. **Perceived performance over raw throughput.** A useful lower-quality frame should appear immediately and improve progressively.
3. **Native interaction.** The UI should behave like a first-class iOS/iPadOS app, not a web or cross-platform UI hosted inside a native shell.
4. **Immich is the backend, not the UX specification.** Otter may use Immich data and APIs without copying the official client information architecture.
5. **Arbitrary Immich servers.** The client must adapt to different server versions, derivative sizes, formats, permissions, and configuration choices.
6. **Strict scope.** Features that do not improve browsing, viewing, rating, or explicit download should require a separate product decision before entering scope.
7. **Instrumented performance.** Performance work must be validated with Instruments and measurable budgets rather than visual intuition alone.

## Current platform scope

- iPhone: supported
- iPad: supported
- Minimum deployment target: **iOS/iPadOS 18+**
- macOS: **not a current product target**
- First release image scope: static images, SDR / Display P3
- HDR, video, Live Photo, RAW-specific behavior, and deep tiled zoom are later phases

## Authoritative documents

- [Product Definition](product.md) — product scope, UX semantics, non-goals, and platform decisions.
- [Architecture](architecture.md) — system boundaries, packages, server compatibility, metadata ownership, and data flow.
- [Media Pipeline](media-pipeline.md) — caching, scheduling, request coalescing, decoding, prefetch, cancellation, error handling, metrics, and tests.
- [Brand and Naming](branding.md) — Otter brand semantics, public naming, engineering naming, and visual direction.
- [Decision Log](decisions.md) — decisions that should not be silently reversed during implementation.

## Delivery evidence

- [Execution Report — 2026-08-10](execution-report-2026-08-10.md) — the consolidated feature inventory, reproducible test methods, results, live read-only verification, performance figures, audit fixes, and remaining release gates for this implementation round.
- [Implementation Status](implementation-status.md) — requirement-by-requirement completion and limitations.
- [Performance Baseline](performance-baseline.md) — detailed ETTrace and memgraph interpretation.
- [Immich API Contract](immich-api-contract.md) — the exact public Immich surface and fallback semantics.

## Requirement language

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are used intentionally in these documents. A MUST-level rule should only be changed by updating the relevant documentation and recording the change in the decision log.

## One-sentence product definition

> **Otter is a fast, native photo experience for browsing an Immich library, with lightweight rating and explicit download as the only mutation/export workflows.**
