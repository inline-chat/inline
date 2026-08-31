---
title: "Schema"
description: "Entry points for Inline's HTTP API and realtime protocol schemas."
---

| Surface | Format | Reference |
| --- | --- | --- |
| Bot API | OpenAPI | [Schema](/docs/technical/api-schema) · [JSON](https://inline.chat/openapi.json) · [Methods](https://api.inline.chat/bot-api-reference) |
| Realtime application | Protocol Buffers | [Schema](/docs/technical/protocol-schema) · [core.proto](https://github.com/inline-chat/inline/blob/main/proto/core.proto) |
| Realtime transport | Inline Protocol v1 | [Protocol](/docs/technical/protocol) · [Realtime](/docs/technical/realtime) |

## IDs, Time, and Text

| Value | Convention |
| --- | --- |
| Realtime IDs | Protocol Buffer 64-bit integers. TypeScript SDK outputs use `bigint`; numeric inputs must be safe integers. Do not convert arbitrary IDs to JavaScript `number`. |
| Bot API IDs | JSON numbers within the Bot API's supported range; ID inputs may also be decimal strings. See the generated types for each field. |
| Message identity | Store `(chat_id, message_id)` together. Message IDs are scoped to a chat. |
| Timestamps | Unix seconds unless a field explicitly says otherwise. JavaScript `Date` takes milliseconds: `new Date(seconds * 1000)`. |
| Message entity offsets | UTF-16 code units, not Unicode code points or UTF-8 bytes. Emoji can occupy more than one unit. |
| Send identity | Realtime `SEND_MESSAGE.random_id` is a stable, non-zero signed 64-bit value for the same logical send. Reuse it only for that operation. |

For application JSON containing `bigint`, encode IDs as decimal strings instead of calling `JSON.stringify` on raw SDK objects:

```ts
const json = JSON.stringify(value, (_key, item) =>
  typeof item === "bigint" ? item.toString() : item,
)
```

This is a storage/export convention, not a replacement for Protocol Buffer wire encoding. [TypeScript ID helpers](https://github.com/inline-chat/inline/blob/main/sdk/src/ids.ts)
