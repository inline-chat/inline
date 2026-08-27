---
title: "Files"
description: "File uploads, identity, authorization, and recovery across Inline APIs."
---

## Bot API

Bots upload files with `uploadFile`. A Bot may fetch or reuse a `file_id` only for files it uploaded or files contained in a message it can currently access.

[Bot API setup and reference](/docs/bot-api)

## Realtime Uploads

Realtime V3 uses five RPCs:

```text
createUpload
saveUploadPart
getUploadState
finishUpload
cancelUpload
```

Part size: 512 KiB. Maximum: 1,000 parts and 500 MiB. Parts may arrive out of order. Identical retries succeed; conflicting bytes at an accepted index fail.

Clients preserve the upload ID, reconcile accepted indices after reconnect, and commit a whole-file SHA-256. `finishUpload` reserves one canonical result for reconciliation or same-ID retry.

Uploads bind to the user, account session, and authorization key. Revocation or logout prevents further access.

## Reference

- [TypeScript upload helpers](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts)
- [Rust native upload client](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs)
- [Realtime V3 upload contract](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
