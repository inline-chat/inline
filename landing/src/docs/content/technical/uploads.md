---
title: "Uploads"
description: "Resumable realtime file uploads and recovery."
---

Use the realtime upload methods to transfer photo, video, document, or voice bytes over encrypted RPCs. Completion returns typed media and a `file_unique_id`; sending a message with that media is a separate call. Bot HTTP clients use [`uploadFile`](/docs/technical/files#choose-a-file-api) instead.

## Before you begin

Use an authenticated realtime session. On V3, the upload belongs to its user, account session, and permanent auth key. Keep access to the same source bytes throughout retries. To resume after a process restart, persist the 16-byte `client_upload_id`, returned 16-byte `upload_id`, and source identity. Preserve the exact create metadata and whole-file digest.

| Media kind | Maximum file size |
| --- | ---: |
| Photo | 40,000,000 bytes |
| Video | 200,000,000 bytes |
| Document | 200,000,000 bytes |
| Voice | 20,000,000 bytes |

The part size is currently 524,288 bytes, with at most 1,000 parts. The media limit above is the operative file-size limit. A file must contain at least one byte. `CREATE_UPLOAD` supplies a 32-byte whole-file SHA-256 digest, a nonempty file name and MIME type (each at most 255 characters), and kind-specific metadata. Photos accept JPEG or PNG MIME types. See [`CreateUploadInput`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) for fields.

## Upload a file

1. Generate and retain a 16-byte `client_upload_id`. Compute SHA-256 over the source bytes.
2. Call `CREATE_UPLOAD` with that identity, metadata, byte count, and digest. Keep `upload_id`, `part_size`, `part_count`, `expires_at` (Unix seconds), and `accepted_parts`.
3. Send every unaccepted zero-based part with `SAVE_UPLOAD_PART`. Every part except the final one must have exactly `part_size` bytes; the final part has the remainder. Parts can arrive out of order.
4. Call `FINISH_UPLOAD`. If it reports processing, wait `retry_after_seconds` and query or finish the **same** upload. Continue until `complete` or `failed`.
5. Use returned typed media in a separate send operation. Verify the send result before treating the file as posted to a chat.

An identical retry of an accepted part succeeds with `already_present: true`. Reusing its index with different bytes fails. Replaying `CREATE_UPLOAD` with the same owner, `client_upload_id`, and metadata returns the existing upload and accepted indices; changing metadata conflicts.

### TypeScript helper

The [`NativeUploadClient`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts) handles hashing, part scheduling, reconciliation, and finish polling. Its `upload()` promise resolves with `UploadComplete`, not a sent message. Construct it with a `NativeUploadRpcTransport` backed by your authenticated realtime RPC caller; `rpcUploadTransport` maps the five methods and result variants. For an in-memory source, pass `uploadByteSource(bytes)`. Supply an `AbortSignal` if the caller may stop waiting. Persist `clientUploadId` yourself if the upload must survive process restart.

The [Rust native upload helper](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs) implements the corresponding flow for `inline-sdk` clients. Both helpers require transports with bounded RPC deadlines; their retry budgets and scheduling are implementation choices, not additional server guarantees.

## Finish and recovery

After a timeout or lost response, first call `GET_UPLOAD_STATE` with the existing `upload_id`. A timeout does not prove the server rejected a part or finish request.

| State | Recovery |
| --- | --- |
| `UPLOADING` | Use `accepted_parts` to send missing indices, then finish. |
| `PROCESSING` | Wait before querying the same upload again. `FINISH_UPLOAD.processing` supplies `retry_after_seconds`; the current service returns 2 seconds. |
| `COMPLETE` | Use `complete`, which contains `file_unique_id` and one typed media value. |
| `FAILED` | Inspect `failure.code` and `failure.retryable`; reconcile the original upload before deciding on a new attempt. |
| `CANCELED` or `EXPIRED` | Stop sending parts. Start a new upload only if the caller still wants the file. |

`FINISH_UPLOAD.missing.part_indices` identifies the parts to send before finishing again. `FINISH_UPLOAD.processing` does not mean finalization completed. Do not create a second upload after a lost finish response. The server checks the whole-file digest during finalization; integrity or media-validation errors become a failed upload.

An active upload expires after 24 hours without an accepted part, with an absolute lifetime of seven days. Each accepted part can extend idle expiry up to that hard limit. The `expires_at` returned at creation is the current idle deadline, not a permanent reservation.

## Ownership and cancellation

The owner is the user and account session; V3 additionally binds the permanent auth key. Temporary-key rotation preserves ownership. Revoking the session, logging out, or revoking the permanent key prevents access. Another session cannot resume merely by knowing `upload_id`.

`CANCEL_UPLOAD` returns `canceled` and `already_terminal`. It can cancel an uploading transfer and reports an already terminal result for completed, failed, or previously canceled transfers. Once finalization is processing, it can return `canceled: false` and `already_terminal: false`; query state until it settles. Aborting the TypeScript helper ends the local wait and makes a bounded best-effort cancel call. Reconcile state if confirmed cancellation matters.

## Method reference

| Method | Input | Result and completion boundary |
| --- | --- | --- |
| `CREATE_UPLOAD` | `client_upload_id`, metadata, `byte_count`, `sha256`, `kind` | Returns `upload_id`, geometry, expiry, and accepted indices after admission; file bytes are not complete. |
| `SAVE_UPLOAD_PART` | `upload_id`, `part_index`, exact `data` | Returns `already_present` after the part is accepted. |
| `GET_UPLOAD_STATE` | `upload_id` | Returns status, accepted indices, and optional completion or failure detail. |
| `FINISH_UPLOAD` | `upload_id` | Returns `missing`, `processing`, `complete`, or `failed`; processing is not completion. |
| `CANCEL_UPLOAD` | `upload_id` | Reports whether cancellation occurred or the upload was already terminal. |

All methods require the upload owner. Invalid input, ownership mismatch, part conflict, or admission capacity can produce RPC errors; inspect the error before retrying. The current service limits each account session to 20 active uploads and 2 GiB of reserved upload bytes; admission beyond either limit returns a rate-limit error. See [RPC Semantics](/docs/technical/rpc) for commit-unknown requests and [Protocol Schema](/docs/technical/protocol-schema) for exact wire fields.
