---
title: "Realtime API"
description: "WebSocket endpoints and TypeScript quick start."
---

## Versions

- V3: `wss://api.inline.chat/realtime/v3` — Inline Protocol keys; current.
- V2: `wss://api.inline.chat/realtime` — bearer token; compatibility.

## Install

Bun:

```bash
bun add @inline-chat/realtime-sdk
```

npm:

```bash
npm install @inline-chat/realtime-sdk
```

## V2 Quick Start

Set `INLINE_TOKEN` and `INLINE_CHAT_ID`. Save as `send-realtime.ts`:

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const token = process.env.INLINE_TOKEN
const chatId = process.env.INLINE_CHAT_ID
if (!token || !chatId) throw new Error("Set INLINE_TOKEN and INLINE_CHAT_ID")

const client = new InlineSdkClient({ token })
try {
  await client.connect()
  await client.sendMessage({ chatId: BigInt(chatId), text: "Hello over Realtime" })
} finally {
  await client.close()
}
```

Run it:

```bash
bun run send-realtime.ts
```

Verify the message in Inline.

## V3

V3 requires `inlineProtocol.credentials` with permanent and bound temporary authorization keys. A bearer token cannot authenticate V3.

- [V3 authentication and transport](/docs/technical/realtime)
- [Protocol specification](https://github.com/inline-chat/inline/blob/main/packages/protocol/docs/realtime-v3.md)
- [TypeScript implementation](https://github.com/inline-chat/inline/tree/main/sdk/src/realtime)
- [RPC retry rules](/docs/technical/rpc)
- [Sync](/docs/technical/sync)
- [Rust SDK](/docs/rust-sdk)
