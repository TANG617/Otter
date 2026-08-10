# Brand and Naming

## 1. Product name

The product name is:

> **Otter**

Do not rename the core product to `Otter Photos`, `Immich Otter`, `Otter Viewer`, or another descriptive compound without an explicit product decision.

When context is needed, use a descriptor rather than changing the brand name.

Recommended public forms:

- **Otter — Native Photos for Immich**
- **Otter for Immich**
- **Otter — A native photo experience for Immich**

The app itself should normally display simply **Otter**.

---

## 2. Brand meaning

Otter should evoke:

- fluid movement;
- lightness;
- ease;
- quiet speed;
- playful but controlled character;
- effortless navigation through a large body of photos.

The core metaphor is not “an animal that stores photos.” It is:

> **Browsing should feel like gliding through water.**

This aligns the brand with the product's most important quality: smooth, continuous photo browsing.

The name should not be used to justify ornamental or novelty UX.

---

## 3. Product language

### Preferred concise positioning

> **A fast, native photo experience for your Immich library.**

Alternative:

> **Your photos. Your server. Native.**

Internal engineering description:

> **A high-performance native Immich viewer for iOS/iPadOS.**

The word `viewer` is useful internally because it enforces scope. Public-facing copy may use `photo experience` or `native photos` because the product is more than a basic file viewer.

---

## 4. Core vocabulary

The product is organized around four verbs:

> **Browse. View. Rate. Download.**

Prefer these terms in product and engineering discussions.

### Use

- Library
- Timeline
- Viewer
- Current Version
- Original
- Rating
- Download
- Media Cache
- Server
- Immich Server

### Avoid unnecessary animal metaphors

Do not rename ordinary concepts into gimmicks such as:

- Otter Pond
- Otter Nest
- Swimming Photos
- Dive Mode
- Catch
- Shell Collection

Otter is the brand, not a vocabulary replacement system.

---

## 5. Tone

Otter's UI should feel:

- concise;
- calm;
- direct;
- image-first;
- technically trustworthy;
- friendly without being childish.

Avoid excessive explanatory copy during normal browsing. The best viewer UI disappears behind the photo.

Error and compatibility messages should be precise rather than cute.

Good:

> Current Version cannot be downloaded from this server. You can download the Original instead.

Bad:

> This otter couldn't fetch your photo. Try swimming again!

---

## 6. Visual identity direction

The app icon should not begin as a cartoon mascot.

Desired hierarchy:

1. first impression: clean, memorable visual mark;
2. second impression: subtle otter association;
3. optional third impression: viewing/photo/frame association.

Promising visual ingredients:

- simplified otter head silhouette;
- eye/observation motif;
- frame/viewfinder geometry;
- water ripple or smooth flowing curve;
- abstract body/whisker/ear geometry;
- strong silhouette that survives small icon sizes.

Avoid:

- detailed furry illustration;
- children's-app facial expression;
- camera-lens cliché as the entire mark;
- literal NAS/server imagery;
- copying Immich's flower/logo language;
- iconography that implies backup/upload as the main feature.

The brand should visually communicate **fluid browsing**, not storage infrastructure.

---

## 7. UI relationship to Apple Photos

Otter should learn from Apple Photos' interaction grammar without attempting a pixel-for-pixel clone.

Borrow principles such as:

- image-first hierarchy;
- direct manipulation;
- immediate gesture feedback;
- low-chrome fullscreen viewing;
- continuity between timeline and viewer;
- natural zoom/pan behavior;
- restrained controls.

Do not copy Apple-specific branding, proprietary visual assets, or arbitrary layout details that do not fit Otter's narrower workflow.

---

## 8. Repository and target naming

Repository:

```text
TANG617/Otter
```

Xcode workspace/project/app target:

```text
Otter
```

Prefer clear functional package names rather than prefixing every module with `Otter`:

```text
MediaCore
ImmichKit
AssetStore
MediaCache
MediaPipeline
MediaUI
AssetExport
```

This is preferred over:

```text
OtterMediaCore
OtterImmichKit
OtterAssetStore
OtterMediaPipeline
...
```

The repository already supplies the product namespace; repeating it everywhere adds noise.

---

## 9. Swift naming conventions

### Domain names

Prefer names that describe semantics rather than implementation:

```swift
MediaAssetDescriptor
AssetVariant
MediaRequest
MediaFrame
RenderSurface
RepresentationPlanner
RequestCoordinator
MediaPriority
AssetExporter
```

Avoid vague generic names:

```swift
Manager
Helper
Utils
ImageService
NetworkManager
Common
Shared
```

If a type ends in `Manager`, it should have a clearly defined coordination responsibility that cannot be named more precisely.

### Protocols

Use capability-oriented names where natural:

```swift
MediaDecoding
AssetExporting
```

Use `...Protocol` only when avoiding a collision or when the protocol is intentionally the primary public abstraction.

### API adapter names

Version-specific Immich implementation names may use:

```text
ImmichV2Adapter
ImmichV3Adapter
```

only when multiple versions genuinely require different behavior. Do not pre-create empty version layers.

---

## 10. File and directory naming

Use lowercase kebab-case for Markdown documentation:

```text
docs/
  product.md
  architecture.md
  media-pipeline.md
  branding.md
  decisions.md
```

Swift files use the primary type name:

```text
MediaPipeline.swift
RequestCoordinator.swift
ByteDiskCache.swift
```

Avoid generic files such as:

```text
Helpers.swift
Extensions.swift
Utils.swift
Common.swift
```

Prefer focused extensions beside their domain or in explicitly named files.

---

## 11. Public naming and Immich relationship

Otter is an independent client using Immich as its backend.

Recommended description:

> **Otter for Immich**

or:

> **Otter — Native Photos for Immich**

Do not imply that Otter is the official Immich iOS application unless that relationship actually exists.

Public branding should make the compatibility relationship clear while keeping **Otter** as the primary brand.

---

## 12. Trademark/name diligence

`Otter` is a common English word and is used by existing products in the software market. Before public commercial release, perform a dedicated check for:

- App Store naming conflicts;
- relevant software trademarks in intended markets;
- domains and social handles;
- potential confusion with existing technology products.

This diligence is a release/branding task; it does not block use of **Otter** as the current repository and product-development name.
