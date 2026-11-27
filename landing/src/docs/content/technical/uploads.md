---
title: "Uploads"
description: "Resumable realtime file uploads and recovery."
---

Use the realtime upload methods to transfer photo, video, document, or voice bytes over encrypted RPCs. Completion returns typed media and a `file_unique_id`; sending a message with that media is a separate call. Bot HTTP clients use [`uploadFile`](/docs/technical/files#choose-a-file-api) instead.

## About this page

For SDK users uploading a document and adapter authors implementing resumable transfers. The common SDK path comes first; wire-method scheduling and helper internals follow it. Success is a completed media result; verify the separate send when posting it to a chat.

**Applies to:** Realtime V2 and V3 uploads; TypeScript SDK. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

## Before you begin

Use an authenticated realtime session. On V3, the upload belongs to its user, account session, and permanent auth key. Keep access to the same source bytes throughout retries. To resume after a process restart, persist the 16-byte `client_upload_id`, returned 16-byte `upload_id`, and source identity. Preserve the exact create metadata and whole-file digest.

| Media kind | Maximum file size |
| --- | ---: |
| Photo | 40,000,000 bytes |
| Video | 500,000,000 bytes |
| Document | 500,000,000 bytes |
| Voice | 20,000,000 bytes |

The part size is currently 524,288 bytes, with at most 1,000 parts. The media limit above is the operative file-size limit. A file must contain at least one byte. `CREATE_UPLOAD` supplies a 32-byte whole-file SHA-256 digest, a nonempty file name and MIME type (each at most 255 characters), and kind-specific metadata. Photos accept JPEG or PNG MIME types. See [`CreateUploadInput`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) for fields.

## Upload a document with TypeScript

This example uses Bun `1.4.0` and `@inline-chat/realtime-sdk` `0.0.19-alpha.0`. [Install the SDK](/docs/realtime-api#install) and supply `INLINE_TOKEN` for the [V2 compatibility connection](/docs/realtime-api#v2-quick-start). V2 protects these calls with WSS; an existing V3 application can use its key-based client for the same `uploadFile()` call.

The sample uploads a small document and prints its completed media identity. It does not send a message. Save it as `upload-document.ts`:

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const token = process.env.INLINE_TOKEN
const uploadHex = process.env.INLINE_UPLOAD_ID
if (!token || !uploadHex || !/^[0-9a-f]{32}$/i.test(uploadHex)) {
  throw new Error("Set INLINE_TOKEN and INLINE_UPLOAD_ID (32 hexadecimal characters)")
}
const clientUploadId = Uint8Array.from(Buffer.from(uploadHex, "hex"))
const source = new TextEncoder().encode("Quarterly report\n")
const client = new InlineSdkClient({ token, rpcTimeoutMs: 15_000 })
try {
  await client.connect(AbortSignal.timeout(15_000))
  const uploaded = await client.uploadFile({
    type: "document",
    file: source,
    fileName: "report.txt",
    contentType: "text/plain",
    clientUploadId,
    signal: AbortSignal.timeout(120_000),
  })
  if (uploaded.documentId === undefined || !uploaded.fileUniqueId) {
    throw new Error("No completed document returned; reconcile the upload before retrying")
  }
  console.log(`Completed file ${uploaded.fileUniqueId}; document ${uploaded.documentId}`)
} catch (error) {
  console.error("Upload did not report completion. Keep the upload ID and original bytes for recovery.")
  throw error
} finally {
  await client.close()
}
```

Generate an upload identity once and retain the printed value with this source file and its metadata:

```bash
bun -e 'console.log(Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex"))'
```

Set `INLINE_UPLOAD_ID` to that value, then run:

```bash
bun run upload-document.ts
```

**Verify:** `Completed file …; document …` means finalization returned a document. Store both identities if later work will attach it. To post it, use `sendMessage({ chatId, media: { kind: "document", documentId } })` in your sender and verify the message result under the [send retry contract](/docs/technical/rpc#stable-identities).

After a lost response, reuse the same `INLINE_UPLOAD_ID`, bytes, name, MIME type, and account session; the helper reconciles the existing transfer. Do not generate a new ID merely because a response was lost. A canceled or expired upload needs the [terminal-state recovery](#finish-and-recovery) below. The two-minute deadline aborts local work and triggers best-effort cancellation; it does not certify remote cancellation.

## Upload a file

This wire-level sequence is for adapter authors. SDK applications can use the preceding example and skip part scheduling.


1. Generate and retain a 16-byte `client_upload_id`. Compute SHA-256 over the source bytes.
2. Call `CREATE_UPLOAD` with that identity, metadata, byte count, and digest. Keep `upload_id`, `part_size`, `part_count`, `expires_at` (Unix seconds), and `accepted_parts`. A file of at most one part can carry its bytes in `inline_data`: the server stores and finishes it in the same call and returns `complete`. If `complete` is absent, continue with the steps below; part 0 is listed in `accepted_parts` when the server kept it. To skip waiting for the reply before sending parts, propose a 16-byte `upload_id` (derive it from `client_upload_id` so a replay proposes the same one). A server that returns your proposed ID holds parts that arrive just ahead of their create, so later uploads can send parts right behind the create; if it returns a different ID, wait for create replies.
3. Send every unaccepted zero-based part with `SAVE_UPLOAD_PART`. Every part except the final one must have exactly `part_size` bytes; the final part has the remainder. Parts can arrive out of order, and several can be in flight at once.
4. Call `FINISH_UPLOAD`. A video or document that did not name its thumbnail in `CREATE_UPLOAD` can name it here with `thumbnail_file_unique_id`, so the file can start uploading before its thumbnail is done. If it reports `missing`, send those parts and finish again. If it reports processing, wait `retry_after_seconds` and query or finish the **same** upload. Continue until `complete` or `failed`.
5. Use returned typed media in a separate send operation. Verify the send result before treating the file as posted to a chat.

The server replies to `SAVE_UPLOAD_PART` once it holds the bytes and stores them after replying, so a reply means received, not stored. A part it loses before storing it, after a failed write or a restart, is reported by `FINISH_UPLOAD` in `missing`; send it again. An identical retry of a part the server already has succeeds with `already_present: true`. Do not reuse an index with different bytes: the whole-file digest check fails the upload.

### Send a part in pieces

When `CREATE_UPLOAD` returns `piece_granularity`, a part can also arrive in pieces, so progress can start after a few kilobytes instead of a whole part. Send each piece with `SAVE_UPLOAD_PART`, the part's `part_index`, and the piece's byte `offset` inside the part. A piece starts at a multiple of `piece_granularity` and is a multiple of it long, except the piece that ends its part. Pieces can arrive in any order and can be resent. The part joins `accepted_parts` once all of its bytes have arrived. If `piece_granularity` is absent, send whole parts. Replaying `CREATE_UPLOAD` with the same owner, `client_upload_id`, and metadata returns the existing upload and accepted indices; changing metadata conflicts.

### TypeScript helper

The [`NativeUploadClient`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts) handles hashing, part scheduling, reconciliation, and finish polling. Its `upload()` promise resolves with `UploadComplete`, not a sent message. Construct it with a `NativeUploadRpcTransport` backed by your authenticated realtime RPC caller; `rpcUploadTransport` maps the five methods and result variants. For an in-memory source, pass `uploadByteSource(bytes)`. Supply an `AbortSignal` if the caller may stop waiting. Persist `clientUploadId` yourself if the upload must survive process restart.

The [Rust native upload helper](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs) implements the corresponding flow for `inline-sdk` clients. Both helpers require transports with bounded RPC deadlines; their retry budgets and scheduling are implementation choices, not additional server guarantees.

## Finish and recovery

After a timeout or lost response, first call `GET_UPLOAD_STATE` with the existing `upload_id`. A timeout does not prove the server rejected a part or finish request.

| State | Recovery |
| --- | --- |
| `UPLOADING` | Use `accepted_parts` to send missing indices, then finish. |
| `PROCESSING` | Wait before querying the same upload again. `FINISH_UPLOAD.processing` supplies `retry_after_seconds`; the current service returns 1 second. |
| `COMPLETE` | Use `complete`, which contains `file_unique_id` and one typed media value. |
| `FAILED` | Inspect `failure.code` and `failure.retryable`; reconcile the original upload before deciding on a new attempt. |
| `CANCELED` or `EXPIRED` | Stop sending parts. Start a new upload only if the caller still wants the file. |

`FINISH_UPLOAD.missing.part_indices` identifies the parts to send before finishing again. `FINISH_UPLOAD.processing` does not mean finalization completed. Do not create a second upload after a lost finish response. The server checks the whole-file digest during finalization; integrity or media-validation errors become a failed upload.

An active upload expires about 24 hours after its last accepted part, with an absolute lifetime of seven days. Accepted parts extend idle expiry up to that hard limit, at most once an hour, so the idle deadline can fall up to an hour sooner than 24 hours after the latest part. The `expires_at` returned at creation is the current idle deadline, not a permanent reservation.

## Ownership and cancellation

The owner is the user and account session; V3 additionally binds the permanent auth key. Temporary-key rotation preserves ownership. Revoking the session, logging out, or revoking the permanent key prevents access. Another session cannot resume merely by knowing `upload_id`.

`CANCEL_UPLOAD` returns `canceled` and `already_terminal`. It can cancel an uploading transfer and reports an already terminal result for completed, failed, or previously canceled transfers. Once finalization is processing, it can return `canceled: false` and `already_terminal: false`; query state until it settles. Aborting the TypeScript helper ends the local wait and makes a bounded best-effort cancel call. Reconcile state if confirmed cancellation matters.

## Method reference

| Method | Input | Result and completion boundary |
| --- | --- | --- |
| `CREATE_UPLOAD` | `client_upload_id`, metadata, `byte_count`, `sha256`, `kind`, optional `upload_id` and `inline_data` | Returns `upload_id`, geometry, expiry, and accepted indices after admission; file bytes are not complete. |
| `SAVE_UPLOAD_PART` | `upload_id`, `part_index`, exact `data`, optional `offset` for a piece | Returns `already_present` once the server holds the bytes; `FINISH_UPLOAD` reports any it lost. |
| `GET_UPLOAD_STATE` | `upload_id` | Returns status, accepted indices, and optional completion or failure detail. |
| `FINISH_UPLOAD` | `upload_id`, optional `thumbnail_file_unique_id` | Returns `missing`, `processing`, `complete`, or `failed`; processing is not completion. |
| `CANCEL_UPLOAD` | `upload_id` | Reports whether cancellation occurred or the upload was already terminal. |

All methods require the upload owner. Invalid input, ownership mismatch, part conflict, or admission capacity can produce RPC errors; inspect the error before retrying. While part storage is unavailable, `SAVE_UPLOAD_PART` returns a retryable service-unavailable error (code 503) with `retry_after_seconds`, currently 5; wait and resend. The current service limits each account session to 20 active uploads and 2 GiB of reserved upload bytes; admission beyond either limit returns a rate-limit error. See [RPC Semantics](/docs/technical/rpc) for commit-unknown requests and [Protocol Schema](/docs/technical/protocol-schema) for exact wire fields.

## Summary

Verify two separate outcomes: `uploadFile()` returns completed media; `sendMessage()` returns a message result. Retain the upload identity and source bytes for recovery, and use [RPC retry rules](/docs/technical/rpc#stable-identities) before repeating the send.

## Source

- [`CreateUploadInput`](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- [`NativeUploadClient`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts)
- [Rust native upload helper](https://github.com/inline-chat/inline/blob/main/crates/sdk/src/native_upload.rs)
