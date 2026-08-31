---
title: "Realtime API"
description: "WebSocket API and TypeScript SDK quick start."
---

Inline Realtime carries typed RPCs, updates, and live state over WebSocket. V3 is current; V2 is the bearer-token compatibility path.

## Versions

| Version | Endpoint | Authentication | Status |
| --- | --- | --- | --- |
| V3 | `wss://api.inline.chat/realtime/v3` | Inline Protocol permanent and bound temporary keys | Current protocol |
| V2 | `wss://api.inline.chat/realtime` | Inline bearer token | Compatibility |

## TypeScript

#### Bun

```bash
bun add @inline-chat/realtime-sdk
```

#### npm

```bash
npm install @inline-chat/realtime-sdk
```

## Bearer-Token Quick Start

This example uses **V2 compatibility**, not V3. For a bot integration, [create a bot](/docs/creating-a-bot) and provide its token as `INLINE_TOKEN`. Set `INLINE_CHAT_ID` to a chat the bot can access. A CLI login does not automatically provide a token to this program.

Save as `send-realtime.ts`:

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const token = process.env.INLINE_TOKEN
const chatId = process.env.INLINE_CHAT_ID
if (!token || !chatId) throw new Error("Set INLINE_TOKEN and INLINE_CHAT_ID")

const client = new InlineSdkClient({ token })
try {
  await client.connect()
  await client.sendMessage({ chatId: BigInt(chatId), text: "Hello over Realtime" })
  console.log("Message accepted. Verify it in Inline.")
} finally {
  await client.close()
}
```

Run with [Bun](https://bun.sh):

```bash
bun run send-realtime.ts
```

Confirm the message appears in the intended chat. Connection success alone does not prove the send succeeded. Before adding retries or a persistent cache, read [RPC semantics](/docs/technical/rpc) and [Sync](/docs/technical/sync).

## Using V3

V3 requires `inlineProtocol.credentials` with Inline Protocol authorization keys. A bearer token and a different endpoint are not sufficient. Follow the [V3 authentication lifecycle](/docs/technical/realtime#authentication-lifecycle) and the SDK's [V3 client implementation](https://github.com/inline-chat/inline/blob/main/sdk/src/realtime/v3-client.ts).

## Reference

- [Realtime V3](/docs/technical/realtime)
- [Inline Protocol](/docs/technical/protocol)
- [TypeScript V3 source](https://github.com/inline-chat/inline/tree/main/sdk/src/realtime)
- [Rust SDK](/docs/rust-sdk)
- [core.proto](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- [`@inline-chat/protocol`](https://github.com/inline-chat/inline/tree/main/packages/protocol)
