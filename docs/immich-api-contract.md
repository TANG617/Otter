# Immich API Contract

## Audit baseline

This contract was checked on 2026-08-10 against the official Immich v3.1.0 release and frozen OpenAPI document. Otter implements only the surface below and must not imply support for untested future major versions.

Official sources:

- [Immich v3.1.0 release](https://github.com/immich-app/immich/discussions/30359)
- [Immich v3.1.0 OpenAPI](https://github.com/immich-app/immich/blob/v3.1.0/open-api/immich-openapi-specs.json)
- [API-key authentication](https://api.immich.app/authentication)
- [Sync API-key restriction](https://github.com/immich-app/immich/blob/v3.1.0/server/src/services/sync.service.ts#L83-L85)

## Authentication

Otter sends the API key only in the `x-api-key` request header. It never uses the documented `apiKey` query parameter. Protected redirects may retain the credential only for the normalized server origin; a redirect to another origin is rejected before credentials can be forwarded.

Minimum useful permission is `asset.read` plus `asset.view`. Download requires `asset.download`; rating write requires `asset.update`. API-key credentials cannot call the sync stream even when `sync.stream` permission is present.

## Endpoint surface

| Purpose | Endpoint | Status in v3.1.0 | Permission | Otter behavior |
|---|---|---|---|---|
| Server version | `GET /api/server/version` | Stable | none | Required connection probe; reads major/minor/patch/prerelease. |
| Metadata bootstrap/reconciliation | `POST /api/search/metadata` | Stable | `asset.read` | Pages by `page`/`size`, uses `withExif=true`, treats `nextPage` only as a continuation token. |
| Asset detail / rating verification | `GET /api/assets/{id}` | Stable | `asset.read` | Maps the minimum Asset/Exif fields to domain values. |
| Thumbnail/preview/fullsize | `GET /api/assets/{id}/thumbnail?size=...&edited=...` | Stable | `asset.view` | Supports `thumbnail`, `preview`, and `fullsize`; records actual MIME/dimensions/redirect behavior. |
| Original/current file | `GET /api/assets/{id}/original?edited=...` | Stable | `asset.download` | `edited=false` is Original. `edited=true` is the server current rendition and can resolve to original pixels when no edit exists. |
| Rating write | `PUT /api/assets/{id}` with `{rating}` | Deprecated endpoint; rating field Stable | `asset.update` | Optional capability only; accepts `-1`, `1...5`, or `null`; verifies by reading the asset after the write. Never sends `0`. |
| Download sizing | `POST /api/download/info` | Stable | `asset.download` | Used only when archive sizing is needed. |
| Archive download | `POST /api/download/archive` | Stable | `asset.download` | Used for explicit multi-asset archive export, never media caching. |
| Incremental sync | `POST /api/sync/stream` | Stable but API keys forbidden | `sync.stream` plus session auth | Not called by the API-key MVP. Capability is reported unavailable. |

## DTO fields used

Search reads `assets.items` and `assets.nextPage`; `assets.total` is deprecated and is not a total count in the v3.1 implementation. Otter de-duplicates pages by asset ID.

The asset boundary maps only:

- `id`, `type`, `ownerId`
- `localDateTime`, `fileCreatedAt`, `createdAt`, `updatedAt`
- `width`, `height`, `thumbhash`
- `checksum`, `originalFileName`, `originalMimeType` when available
- `isFavorite`, `isEdited`, archive/trash/visibility fields needed to exclude non-timeline assets
- `exifInfo.rating` when present

DTOs never enter SwiftUI views.

## Bootstrap and incremental behavior

Because API keys cannot use the sync stream, the MVP uses:

1. local database immediately at launch;
2. paged metadata search bootstrap/reconciliation;
3. an `updatedAfter` overlap window with asset-ID de-duplication for ordinary refresh;
4. periodic full reconciliation to detect hard deletes and offset-pagination gaps.

This is not described as real-time sync. A future session-auth decision may add `AssetsV2` and `AssetExifsV1` sync types behind a capability without changing the store contract.

## Media and rendition matrix

Immich has no media size named `current`.

- Current viewer derivatives use `edited=true` with `thumbnail`, `preview`, or `fullsize`.
- Original viewing/export uses `/original?edited=false` and a bounded local downsample for display.
- Current export uses `/original?edited=true`; failure is an explicit capability error and never silently falls back to Original.
- `size=original` on the thumbnail endpoint is deprecated and must not be used.
- Fullsize may redirect to Original or fall back to preview. Otter validates same-origin redirects and records observed behavior in `ServerMediaProfile`.

## Error and capability rules

- `401`: invalidate authentication; no retry loop.
- `403`: report a permission/capability error.
- derivative `404`: short negative cache, then a lower/alternate representation where valid.
- `429`: honor `Retry-After`.
- transient `5xx`/timeout: bounded retry only for visible idempotent work.
- rating write failure or read-back mismatch: roll back optimistic UI and mark write capability unavailable for the session when appropriate.
- major versions above 3 are unverified until probed; versions below 3 are best-effort read-only unless covered by fixtures/live tests.

## Forbidden dependencies

`GET /api/timeline/bucket` and `GET /api/timeline/buckets` are Internal. Otter must never build its primary timeline on either endpoint. A regression script and client tests enforce this rule.

## Verification status

Fixture and URLProtocol contract tests are required for every path above. Live v3.1.0 verification requires `OTTER_TEST_SERVER_URL` and `OTTER_TEST_API_KEY`; absence of those values is reported as skipped, not passed.

