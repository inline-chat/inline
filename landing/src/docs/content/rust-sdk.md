---
title: "Rust SDK"
description: "Rust Realtime SDK and stateful client."
---

Requires Rust 1.96 or newer. Experimental.

## Packages

- `inline-sdk`: RPCs, uploads, identity, and Realtime transport.
- `inline-protocol`: generated Protocol Buffers and secure protocol.
- `inline-client`: stateful cache, sync cursors, pending transactions, and committed events.

## Install

Add the SDK:

```bash
cargo add inline-sdk
```

Add Tokio:

```bash
cargo add tokio --features macros,rt-multi-thread
```

## V2 Quick Start

Set `INLINE_TOKEN`. Save as `src/main.rs`:

```rust
use inline_sdk::{ClientIdentity, RealtimeClient, proto};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("INLINE_TOKEN")?;
    let identity = ClientIdentity::try_new("my-rust-app", "0.1.0")?;

    let mut realtime = RealtimeClient::builder(
        "wss://api.inline.chat/realtime",
        token,
    )
    .identity(identity)
    .connect()
    .await?;

    realtime.call(proto::GetMeInput {}).await?;
    Ok(())
}
```

Run it:

```bash
cargo run
```

## Stateful Client

Add the stateful client:

```bash
cargo add inline-client
```

Use one sync owner. Start with [`inline-client`](https://github.com/inline-chat/inline/tree/main/crates/client) instead of building a second cache around `inline-sdk`.

## Notes

- V3 uses [key-based authentication](/docs/technical/realtime#authentication-lifecycle).
- IDs are `Int64`; TypeScript projections use `bigint`.
- Errors are non-exhaustive.
- Reconcile uncertain mutations before retrying.
- [`inline-sdk`](https://github.com/inline-chat/inline/tree/main/crates/sdk)
