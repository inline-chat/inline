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

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const client = new InlineSdkClient({
  token: process.env.INLINE_TOKEN!,
})

await client.connect()
await client.sendMessage({ chatId: 42, text: "hello" })
await client.close()
```

## Reference

- [Realtime V3](/docs/technical/realtime)
- [Inline Protocol](/docs/technical/protocol)
- [TypeScript V3 source](https://github.com/inline-chat/inline/tree/main/sdk/src/realtime)
- [Rust SDK](/docs/rust-sdk)
- [core.proto](https://github.com/inline-chat/inline/blob/main/proto/core.proto)
- [`@inline-chat/protocol`](https://github.com/inline-chat/inline/tree/main/packages/protocol)
