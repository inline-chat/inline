---
title: "Files"
description: "File identity, access, and download contracts."
---

An uploaded file has a stable identifier, but knowing it does not grant access. A completed upload creates media; sending a message with that media is a separate operation. Use [Uploads](/docs/technical/uploads) for the resumable realtime upload lifecycle.

## About this page

For integration authors choosing how to store and retrieve media. Start with the API comparison, then check access and download ranges. You need an authenticated bot or account and, for another user’s file, access to its containing message. Use [Uploads](/docs/technical/uploads) to implement transfer and recovery.

**Applies to:** Bot API 0.1; Realtime V3 downloads. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

## Choose a file API

| Client | Upload | Retrieve |
| --- | --- | --- |
| Bot HTTP API | `uploadFile` | `getFile` returns a file record, including a temporary `download_url` when available. See the [method reference](https://api.inline.chat/bot-api-reference). |
| Realtime client | `CREATE_UPLOAD` through `FINISH_UPLOAD` | `GET_FILE_PART` retrieves authenticated byte ranges on the encrypted V3 carrier. |

Bot HTTP calls name a file with `file_id`; realtime calls use `file_unique_id`. Both can refer to the same stored file, but each API checks access independently. Keep the identifier returned by your API and supply it in that API's field; knowing it alone does not authorize retrieval.

## Access and identity

The server checks access on each retrieval. A bot may call `getFile` or reuse a `file_id` for a bot-owned upload or a file in a message the bot can access.

For realtime downloads, the uploader can request its own file by `file_unique_id`. Another authorized chat participant must also supply `FileMessageLocation` with the exact `(chat_id, message_id)` that references the file. The server checks chat access and that message's file reference. A locator supplies context for an access check; it does not grant access by itself. Unknown and inaccessible realtime files return the same request error.

## Download byte ranges

`GET_FILE_PART` accepts `file_unique_id`, byte `offset`, `limit`, and an optional message locator. It is available on the encrypted V3 carrier. Set `limit` from 1 to 524,288 bytes. An offset equal to the file size returns an empty range; an offset beyond it fails. Each result contains `offset`, `total_size`, `data`, and the SHA-256 digest of `data`, including an empty EOF range.

The TypeScript [`NativeDownloadClient`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/downloads.ts) verifies each range and yields them in order. The caller owns writing bytes and persisting a resume offset. Resume only from an offset whose preceding bytes have been durably written. Its transport must honor abort and enforce individual RPC deadlines.

## Bot API

Bot HTTP downloads use the URL returned by `getFile` while valid. Fetch a fresh file record after `download_url_expires_at`; do not store the temporary URL as a permanent identity.

## Realtime Uploads

Use [Uploads](/docs/technical/uploads) for creation, parts, state reconciliation, and expiry. `client_upload_id` makes creation repeat-safe for the same owner and metadata; server-issued `upload_id` addresses subsequent calls.

## Finish

`FINISH_UPLOAD` can report missing parts, processing, completion, or failure. Completion returns typed media and `file_unique_id`; it does not send a message. See [finish and recovery](/docs/technical/uploads#finish-and-recovery).

## Ownership

Realtime uploads are bound to the account session and, on V3, the permanent auth key. Revoking that session or key ends access. See [upload ownership and cancellation](/docs/technical/uploads#ownership-and-cancellation).

## Reference

- [Upload task and method contracts](/docs/technical/uploads)
- [Realtime schema](/docs/technical/protocol-schema) — file locators, byte ranges, and upload messages
- [Bot API schema](/docs/technical/api-schema) — `uploadFile`, `getFile`, and `BotFile`

## Summary

Choose an API before choosing an identifier. A file ID locates bytes; the account session and message context determine access. To publish a new attachment, [complete an upload](/docs/technical/uploads) and then send its typed media in a separate mutation.
