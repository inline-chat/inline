# Realtime API

Inline Realtime API is the full API surface over WebSocket RPC.

## Endpoint

- `wss://api.inline.chat/realtime`

## SDK

- Package: `@inline-chat/realtime-sdk`

## Install

```bash
bun add @inline-chat/realtime-sdk
```

## Quick Start

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const client = new InlineSdkClient({
  token: process.env.INLINE_TOKEN!,
})

await client.connect()
const me = await client.getMe()
console.log(me.userId)

await client.sendMessage({
  chatId: 42,
  text: "hello from realtime sdk",
})

await client.close()
```

## Use Cases

- Full client integrations
- Rich two-way bot interactions
- Live state sync and realtime updates

## Protocol Buffers

- [core.proto](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- [Generated protocol npm package (`packages/protocol`)](https://github.com/inline-chat/inline/tree/main/packages/protocol)
