---
title: "Schema"
description: "Choose the Bot HTTP or realtime schema and interpret scalar conventions."
---

Inline has two application schemas. The Bot API is an HTTP and JSON interface described by [OpenAPI](/docs/technical/api-schema). The native realtime API uses Protocol Buffers defined in [`proto/core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto); [Protocol Schema](/docs/technical/protocol-schema) maps its generated packages. Choose the schema matching your client and use its field names and access rules.

## Conventions

| Value | Bot HTTP and JSON | Realtime Protocol Buffers |
| --- | --- | --- |
| Entity IDs | JSON-safe integer responses; applicable input IDs accept a number or decimal string. | `int64` IDs; generated TypeScript uses `bigint`. |
| Time | Unix seconds for API `date` and documented timestamps. | Unix seconds for message `date` and fields documented as timestamps; check individual fields for exceptions. |
| Message identity | Keep conversation ID and message ID together. | Keep `(chat_id, message_id)`; a message ID alone is not a complete location. |
| Text entity offsets | UTF-16 code units. | UTF-16 code units in `Message.message`. |

JavaScript JSON cannot serialize `bigint` directly. Convert it to a decimal string at a JSON boundary, then parse it back before constructing a realtime request:

```ts
const messageId = 9007199254740993n
const json = JSON.stringify({ messageId }, (_key, item) =>
  typeof item === "bigint" ? item.toString() : item,
)
const decoded = JSON.parse(json) as { messageId: string }
const restoredMessageId = BigInt(decoded.messageId)
console.log(restoredMessageId === messageId) // true
```

Do not convert arbitrary 64-bit IDs through a JavaScript `number`; values outside its safe-integer range lose precision. Bot API ID input strings are constrained by that API's supported safe-integer range. Reuse a nonzero realtime `SEND_MESSAGE.random_id` only when retrying the same logical send. See [RPC Semantics](/docs/technical/rpc) for uncertain outcomes.

## Entry Points

- [API Schema](/docs/technical/api-schema) — Bot HTTP methods, envelopes, and generated TypeScript types.
- [Protocol Schema](/docs/technical/protocol-schema) — realtime methods, protobuf messages, and generated packages.
- [Files](/docs/technical/files) — file IDs and access across these surfaces.
