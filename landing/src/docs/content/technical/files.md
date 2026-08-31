---
title: "Files"
description: "File uploads, identity, authorization, and recovery across Inline APIs."
---

## Bot API

Bots upload files with `uploadFile`. A Bot may fetch or reuse a `file_id` only for files it uploaded or files contained in a message it can currently access.

[Bot API setup and reference](/docs/bot-api)

## Realtime Uploads

Native resumable uploads use five RPCs, carried by Realtime V3 or the V2 compatibility transport:

```text
createUpload
saveUploadPart
getUploadState
finishUpload
cancelUpload
```

| Field or limit | Contract |
| --- | --- |
| `client_upload_id` | A stable, opaque 16-byte identity for creating this upload. Reuse it when reconciling a lost create response. |
| `upload_id` | Server-issued identity; preserve it across reconnects and restarts. |
| `sha256` | 32-byte whole-file digest of the immutable source. |
| Part size | The current server negotiates 512 KiB; read `part_size` from the create result. Non-final parts must match it. |
| Maximum | 1,000 parts; 500 MiB. |
| `accepted_parts` | Server-accepted indices returned by creation and state queries. |
| Expiry | 24 hours idle; seven days maximum. |

Parts may arrive out of order. Identical retries succeed; conflicting bytes at an accepted index fail. After a lost response, ask `getUploadState` which parts were accepted rather than trusting local progress.

`getUploadState.status` uses the `UploadStatus` enum, separate from the finish-result oneof: `UPLOAD_STATUS_UPLOADING`, `UPLOAD_STATUS_PROCESSING`, `UPLOAD_STATUS_COMPLETE`, `UPLOAD_STATUS_FAILED`, `UPLOAD_STATUS_CANCELED`, or `UPLOAD_STATUS_EXPIRED`. See [`UploadStatus` and upload messages in the schema](https://github.com/inline-chat/inline/blob/main/proto/core.proto) for exact wire values.

## Finish and Recover

| `finishUpload` result | Next action |
| --- | --- |
| `missing` | Send the returned `part_indices`, then finish again. |
| `processing` | Wait for `retry_after_seconds` (clamped to 1–30 seconds), then reconcile using the same upload ID. |
| `complete` | Use the canonical typed media result. |
| `failed` | Inspect the failure code and `retryable` flag before deciding whether to retry. |

`finishUpload` reserves one canonical result. A disconnect during finalization does not justify creating a second upload. Upload completion supplies media; sending a chat message is a separate operation.

V3 uploads bind to the user, account session, and permanent authorization key. Temporary-key rotation does not change that owner. Revocation or logout prevents further access. Upload bytes stay in encrypted RPCs; there is no HTTP PUT URL or automatic HTTP fallback. Bot API uploads and CDN downloads are separate contracts.

`cancelUpload` reports whether cancellation succeeded or the upload was already terminal. Cancellation during processing may be refused. The beta Rust/CLI owner currently stops waiting locally without promising remote cancellation; server staging remains resumable until expiry.

## Reference

- [TypeScript upload helpers](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts)
- [Rust native upload client](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs)
- [Realtime V3 upload contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
