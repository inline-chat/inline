---
title: "Protocol Schema"
description: "Realtime protobuf source, generated packages, and compatibility rules."
---

[`proto/core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) defines realtime application methods, inputs, results, objects, and updates. [Inline Protocol](/docs/technical/protocol) carries those messages; schema compatibility and transport security are separate concerns. Most applications should use a client package rather than construct transport frames.

## Generated entry points

| Target | Entry point | Purpose |
| --- | --- | --- |
| TypeScript | [`@inline-chat/protocol/core`](https://github.com/inline-chat/inline/tree/main/packages/protocol) | Generated `Method`, `RpcCall`, `RpcResult`, objects, and updates. |
| TypeScript | [`@inline-chat/protocol/uploads`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/uploads.ts) and [`/downloads`](https://github.com/inline-chat/inline/blob/main/packages/protocol/src/downloads.ts) | Upload and download helpers over an authenticated RPC transport. |
| Rust | [`inline-protocol`](https://github.com/inline-chat/inline/tree/main/crates/protocol) | Generated `proto` module and secure protocol primitives. Most Rust applications use [`inline-sdk`](https://github.com/inline-chat/inline/tree/main/crates/sdk). |

The Rust crate builds from its packaged [`crates/protocol/proto/core.proto`](https://github.com/inline-chat/inline/blob/main/crates/protocol/proto/core.proto) copy. In this repository, `proto/core.proto` is canonical. Regenerate outputs and synchronize the Rust copy after schema edits.

## Method and result pairing

`Method` selects the matching `RpcCall.input` oneof member. A successful `RpcResult.result` carries that method's result member; a failed application RPC carries a protobuf `RpcError` instead. For example, `Method.CREATE_UPLOAD` pairs with `createUpload` input and result; `CreateUploadInput` contains the idempotency key and file metadata. See [Uploads](/docs/technical/uploads) for creation, accepted parts, and completion, and [RPC error boundaries](/docs/technical/rpc#completion-and-errors) to distinguish application errors from V3 transport errors.

Generated TypeScript uses `bigint` for protobuf `int64` and `uint64`, `Uint8Array` for `bytes`, and tagged `oneofKind` unions for oneofs. Preserve unknown fields when forwarding messages so newer schema fields can survive an older intermediary. If a durable update is unknown to your client, maintain [sequence coverage](/docs/technical/sync#cursor) before advancing a sync cursor.

This TypeScript example encodes and decodes one request locally. It does not send an RPC:

```ts
import { GetFilePartInput } from "@inline-chat/protocol/core"

const request = GetFilePartInput.create({
  fileUniqueId: "IND_example",
  offset: 0n,
  limit: 524288,
})
const bytes = GetFilePartInput.toBinary(request)
const restored = GetFilePartInput.fromBinary(bytes)
console.log(restored.offset === 0n) // true
```

An authenticated V3 download also requires access to the file. For a file owned by someone else, provide a message locator and follow [Files](/docs/technical/files#access-and-identity).

## Next steps

- [Schema conventions](/docs/technical/schema) — IDs, timestamps, and text offsets.
- [RPC Semantics](/docs/technical/rpc) — retries and commit-unknown outcomes.
- [Realtime API](/docs/technical/realtime) — authenticated requests and updates.
