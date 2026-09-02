---
title: "Schema"
description: "Inline schema entry points and scalar conventions."
---

## Entry Points

- Bot API: [OpenAPI JSON](https://inline.chat/openapi.json) · [Methods](https://api.inline.chat/bot-api-reference)
- Realtime application: [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- Realtime transport: [Inline Protocol](/docs/technical/protocol)
- Generated packages: [API Schema](/docs/technical/api-schema) · [Protocol Schema](/docs/technical/protocol-schema)

## Conventions

- Realtime IDs: 64-bit integers; TypeScript output uses `bigint`.
- Bot API IDs: JSON numbers in the supported range; inputs may accept decimal strings.
- Message identity: store `(chat_id, message_id)`.
- Timestamps: Unix seconds unless documented otherwise.
- Message entity offsets: UTF-16 code units.
- Send identity: reuse a non-zero `SEND_MESSAGE.random_id` only for the same logical send.

Encode `bigint` for JSON:

```ts
const json = JSON.stringify(value, (_key, item) =>
  typeof item === "bigint" ? item.toString() : item,
)
```
