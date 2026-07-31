# Rust SDK

Source: https://inline.chat/docs/rust-sdk

The Rust SDK is the low-level Inline client library for Rust apps, agents, bridges, and command-line tools.

## Packages

- `inline-sdk`: API calls, uploads, client identity, and realtime RPC.
- `inline-protocol`: generated protobuf types used by the SDK.

The SDK does not own a durable cache or sync engine. That belongs in the future higher-level `inline-client` crate.

## Install

From the public repository workspace:

```toml
inline-sdk = { git = "https://github.com/inline-chat/inline", package = "inline-sdk" }
```

When using crates.io after release:

```bash
cargo add inline-sdk
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

    let me = realtime.call(proto::GetMeInput {}).await?;
    let _user = me.user;

    Ok(())
}
```

## Notes

- The SDK uses Rust's standard `log` facade and never initializes a logger.
- Parent apps choose their own logger, such as `env_logger`, `tracing-log`, or a platform logger.
- Debug output redacts bearer tokens, auth challenges, URL credentials, query strings, and local upload paths.
- Use [Realtime API](https://inline.chat/docs/realtime-api) for the TypeScript SDK and raw WebSocket endpoint.
