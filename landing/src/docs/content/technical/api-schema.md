---
title: "API Schema"
description: "Bot HTTP OpenAPI and TypeScript schema entry points."
---

The Bot API is an HTTP and JSON interface for bot integrations. Its [OpenAPI JSON](https://inline.chat/openapi.json) and [interactive method reference](https://api.inline.chat/bot-api-reference) define the current request paths, fields, response bodies, and errors. Read [Bot API setup](/docs/bot-api) to authenticate and make a first request.

## TypeScript packages

| Package | Use |
| --- | --- |
| [`@inline-chat/bot-client`](https://github.com/inline-chat/inline/tree/main/packages/bot-client) | Typed HTTP methods, request transport, and Bot API envelopes. |
| [`@inline-chat/bot-api-types`](https://github.com/inline-chat/inline/tree/main/packages/bot-api-types) | Request and result types for each method, plus shared entities. |

For example, `GetFileParams` is `{ file_id: string }` and `GetFileResult` contains a `file`. `UploadFileParams` carries a `Blob`, media `type`, and optional metadata. The [Files guide](/docs/technical/files) explains the access boundary; consult the method reference for exact limits and status codes.

```ts
import type { BotMethodParams, BotMethodResult } from "@inline-chat/bot-api-types"

const request: BotMethodParams<"getFile"> = { file_id: "known-file-id" }
function showFile(result: BotMethodResult<"getFile">): string {
  return result.file.file_id
}
console.log(showFile({ file: { file_id: request.file_id } }))
```

This local shape example prints `known-file-id`; it does not call the server. Replace the sample ID with a file the authenticated bot owns or can access. `BotMethodResult` is the method's successful result, while an HTTP call returns an envelope with `ok`, `result`, and error fields. See [Bot API responses](/docs/bot-api#responses) for envelope handling.

The repository sources are [`packages/bot-api-types/src/index.ts`](https://github.com/inline-chat/inline/blob/main/packages/bot-api-types/src/index.ts), [`packages/bot-client/src/inline-bot-client.ts`](https://github.com/inline-chat/inline/blob/main/packages/bot-client/src/inline-bot-client.ts), and the [server's OpenAPI route](https://github.com/inline-chat/inline/blob/main/server/src/controllers/bot/bot.ts). Use the served OpenAPI document for the HTTP contract.
