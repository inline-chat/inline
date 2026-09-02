---
title: "Files"
description: "File upload and recovery contracts."
---

## Bot API

- Upload with `uploadFile`.
- Fetch or reuse a `file_id` only for a bot-owned upload or an accessible message.
- [Bot API](/docs/bot-api)

## Realtime Uploads

```text
createUpload
saveUploadPart
getUploadState
finishUpload
cancelUpload
```

Contract:

- `client_upload_id`: stable opaque 16-byte create identity.
- `upload_id`: server-issued identity; preserve across reconnects.
- `sha256`: 32-byte whole-file digest.
- Part size: read `part_size`; currently 512 KiB.
- Maximum: 1,000 parts and 500 MiB.
- `accepted_parts`: server-accepted part indices.
- Expiry: 24 hours idle; seven days maximum.
- Parts may arrive out of order.
- Identical part retries succeed; conflicting bytes fail.

After a lost response, call `getUploadState`.

## Finish

- `missing`: send returned `part_indices`, then finish again.
- `processing`: wait `retry_after_seconds` (1–30), then query the same upload.
- `complete`: use the canonical typed media result.
- `failed`: inspect the code and `retryable` flag.

Do not create a second upload after a lost finish response. Message sending is a separate operation.

## Ownership

- V3 binds an upload to user, account session, and permanent key.
- Temporary-key rotation preserves ownership.
- Revocation or logout ends access.
- Upload bytes stay in encrypted RPCs.
- Bot API upload and CDN download are separate contracts.
- `cancelUpload` may refuse cancellation during processing.

## Reference

- [TypeScript helpers](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts)
- [Rust client](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs)
- [V3 upload contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
