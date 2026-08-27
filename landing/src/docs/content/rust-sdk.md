---
title: "Rust SDK"
description: "Rust SDK quick start for API calls, uploads, and realtime RPC."
---

## Packages

| Package | Use |
| --- | --- |
| `inline-sdk` | API calls, uploads, client identity, and realtime RPC |
| `inline-protocol` | Generated Protocol Buffer types and protocol support |
| `inline-client` | Stateful client with local cache, sync cursors, pending transactions, and committed events |

## Install

```bash
cargo add inline-sdk
```

```bash
cargo add inline-client
```

## Quick Start

```rust
use inline_sdk::{ClientIdentity, RealtimeClient, proto};

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("INLINE_TOKEN")?;
    let identity = ClientIdentity::try_new("my-rust-app", "0.1.0")?;

    let mut realtime = RealtimeClient::builder("wss://api.inline.chat/realtime", token)
        .identity(identity)
        .connect()
        .await?;

    let _me = realtime.call(proto::GetMeInput {}).await?;

    Ok(())
}
```

## Notes

- The SDK uses Rust's `log` facade; the parent app configures the logger.
- Debug output redacts bearer tokens, auth challenges, URL credentials, query strings, and local upload paths.
- [Realtime API](/docs/realtime-api) · [`crates/sdk`](https://github.com/inline-chat/inline/tree/main/crates/sdk) · [`crates/client`](https://github.com/inline-chat/inline/tree/main/crates/client)
