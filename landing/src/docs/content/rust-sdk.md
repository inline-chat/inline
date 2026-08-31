---
title: "Rust SDK"
description: "Choose the Rust SDK or stateful client and run a first authenticated RPC."
---

## Packages

| Package | Use |
| --- | --- |
| `inline-sdk` | API calls, uploads, client identity, and realtime RPC |
| `inline-protocol` | Generated Protocol Buffer types and protocol support |
| `inline-client` | Stateful client with local cache, sync cursors, pending transactions, and committed events |

## Install

Use Rust 1.96 or newer for the current crate release. In a Cargo binary project:

```bash
cargo add inline-sdk
```

```bash
cargo add tokio --features macros,rt-multi-thread
```

## Quick Start

This example uses the **V2 bearer-token compatibility** endpoint. Provide a valid token as `INLINE_TOKEN`; for a bot, use the token from [Create a Bot](/docs/creating-a-bot). V3 has a separate [key-based authentication lifecycle](/docs/technical/realtime#authentication-lifecycle).

Save as `src/main.rs`:

```rust
use inline_sdk::{ClientIdentity, RealtimeClient, proto};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("INLINE_TOKEN")?;
    let identity = ClientIdentity::try_new("my-rust-app", "0.1.0")?;

    let mut realtime = RealtimeClient::builder("wss://api.inline.chat/realtime", token)
        .identity(identity)
        .connect()
        .await?;

    let _me = realtime.call(proto::GetMeInput {}).await?;
    println!("Authenticated GetMe RPC succeeded.");

    Ok(())
}
```

```bash
cargo run
```

The confirmation means an authenticated `GetMe` call completed. It does not send a message or initialize a durable cache.

## Stateful Clients

Add this separately when you need local state and synchronization:

```bash
cargo add inline-client
```

`inline-sdk` owns typed calls and transport helpers. `inline-client` owns a local cache, sync cursors, pending transactions, and committed events. Start with the [stateful client reference](https://github.com/inline-chat/inline/tree/main/crates/client) rather than implementing a second sync owner around the low-level quickstart.

## Notes

- The SDK uses Rust's `log` facade; the parent app configures the logger.
- Debug output redacts bearer tokens, auth challenges, URL credentials, query strings, and local upload paths.
- Error enums are non-exhaustive; keep a fallback match arm. Treat an uncertain mutation as an [RPC reconciliation problem](/docs/technical/rpc), not permission to resend it with a new identity.
- [Realtime API](/docs/realtime-api) · [`crates/sdk`](https://github.com/inline-chat/inline/tree/main/crates/sdk) · [`crates/client`](https://github.com/inline-chat/inline/tree/main/crates/client)
