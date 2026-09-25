---
title: "Realtime API"
description: "Choose Realtime authentication, send a message with TypeScript, and manage the connection lifecycle."
---

The Realtime API carries RPC requests and live updates over a persistent WebSocket connection. Use it when your integration needs live state and the protocol surface used by Inline clients. For a bot that can use HTTP requests and polling or webhooks, start with the [Bot API](/docs/bot-api).

This page covers endpoint selection and a TypeScript V2 send example. The example assumes you already have a valid bearer token and access to the destination chat. For V3 authentication, read [V3](#v3) before constructing a client.

## Versions

| Version | Endpoint | Authentication | Use |
| --- | --- | --- | --- |
| V3 | `wss://api.inline.chat/realtime/v3` | Inline Protocol permanent and bound temporary authorization keys. | Current transport. |
| V2 | `wss://api.inline.chat/realtime` | Bearer token. | Compatibility transport; used by the example below. |

The SDK's `token` option selects V2. V3 uses `inlineProtocol.credentials`; a bearer token cannot authenticate it. Changing the endpoint alone does not migrate authentication.

## Install

The example runs with Bun. Install the TypeScript SDK in your project:

```bash
bun add @inline-chat/realtime-sdk
```

Or install the same package with npm:

```bash
npm install @inline-chat/realtime-sdk
```

## V2 Quick Start

Set `INLINE_TOKEN` to a valid V2 bearer token and `INLINE_CHAT_ID` to a chat that identity can access. Keep the token in your server's environment or secret store. A [bot token](/docs/creating-a-bot) can be used for a bot integration; it does not give the bot your account's permissions.

Save as `send-realtime.ts`:

```ts
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const token = process.env.INLINE_TOKEN
const chatId = process.env.INLINE_CHAT_ID
if (!token || !chatId) throw new Error("Set INLINE_TOKEN and INLINE_CHAT_ID")

const destination = BigInt(chatId)
if (destination <= 0n) throw new Error("INLINE_CHAT_ID must be a positive chat ID")

const client = new InlineSdkClient({ token, rpcTimeoutMs: 15_000 })
try {
  await client.connect(AbortSignal.timeout(15_000))
  const sent = await client.sendMessage({
    chatId: destination,
    text: "Hello over Realtime",
  })
  if (sent.messageId === null) {
    throw new Error("No message ID returned; check the conversation before retrying")
  }
  console.log(`Sent message ${sent.messageId}`)
} finally {
  await client.close()
}
```

Each run sends a new message. Run it once:

```bash
bun run send-realtime.ts
```

Confirm that the command prints a message ID and that the message appears in the intended Inline conversation. If the send fails after dispatch, check the conversation before rerunning the script; the message may already exist.

### Connection and Request Lifecycle

| Operation | What completion means |
| --- | --- |
| `connect(signal)` | The connection is open and authenticated. It does not establish that every history range is synchronized. |
| `sendMessage(...)` | The RPC returned a result; `messageId` is extracted from its updates and can be `null`. |
| `close()` | Disposes this client instance and ends its event stream without revoking credentials. Construct a new client to reconnect. |

Keep `close()` in `finally` so failed connection and send attempts also release resources. The example bounds connection waiting separately from the RPC timeout. A timeout or cancellation ends waiting; it does not prove that a dispatched mutation did not execute.

The SDK generates a message `randomId` when one is omitted. A durable sender should persist a stable nonzero signed 64-bit `randomId` and reuse it only for the same logical send, following the [RPC retry rules](/docs/technical/rpc#stable-identities). Rerunning this example generates a new identity.

## V3

V3 requires `inlineProtocol.credentials` containing an authorized permanent key. You can also supply a stored bound temporary key; if one is absent or cannot be reused, the SDK creates and binds a new one. Establish the permanent authority through the [authentication lifecycle](/docs/technical/authentication), then supply the credentials to `InlineSdkClient` instead of `token`.

Your integration owns durable credential storage. Use `inlineProtocol.onCredentials` to persist replacement credentials before they are used. Store authorization keys as secrets and coordinate replacement with logout so an older write cannot restore revoked local credentials. See the [SDK option contracts](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/types.ts) when implementing that lifecycle.

For implementation details, read the [TypeScript V3 connection](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-connection.ts) and [V3 transport](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-transport.ts). The canonical RPC and update definitions are in [`core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto).

## Troubleshooting

| Symptom | Recovery |
| --- | --- |
| Authentication is rejected | Confirm the endpoint and credential type. Replace invalid or revoked credentials; repeated connection attempts with the same rejected credentials will not fix access. |
| `BigInt` conversion fails | Supply the chat ID as decimal text. Keep IDs as `bigint` in TypeScript to avoid precision loss. |
| A request times out or disconnects | Determine whether it was sent and reconcile uncertain mutations before retrying. See [RPC semantics](/docs/technical/rpc). |
| Reconnecting a closed client fails | Construct a new `InlineSdkClient`; `close()` ends the previous instance's lifecycle. |

## Next Steps

- To maintain state across live updates and reconnects, read [Sync](/docs/technical/sync).
- To handle failures without duplicating mutations, read [RPC semantics](/docs/technical/rpc).
- To implement a Rust client, start with the [Rust SDK](/docs/rust-sdk).
