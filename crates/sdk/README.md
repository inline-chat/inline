# inline-sdk

Rust SDK for Inline API calls, uploads, client metadata, and realtime RPC.

This is the low-level SDK. It does not own a durable cache or sync engine; that
lives in the higher-level `inline-client` crate. Use this crate when you
want typed protocol access, HTTP auth/upload helpers, or a realtime RPC
transport.

```rust
use inline_sdk::{
    ApiClient, ClientIdentity, PeerId, ReadMessagesInput, RealtimeClient,
    UploadFileInput, proto,
};
use std::time::Duration;

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("INLINE_TOKEN")?;
    let identity = ClientIdentity::try_new("my-agent", "0.1.0")?;

    let api = ApiClient::builder("https://api.inline.chat/v1")
        .identity(identity.clone())
        .request_timeout(Duration::from_secs(60))
        .build()?;

    let mut realtime = RealtimeClient::builder("wss://api.inline.chat/realtime", &token)
        .identity(identity)
        .connect_timeout(Duration::from_secs(30))
        .rpc_timeout(Duration::from_secs(60))
        .connect()
        .await?;

    let result = realtime.call(proto::GetMeInput {}).await?;

    let read = ReadMessagesInput::new(PeerId::thread(123)).with_max_id(456);
    api.read_messages(&token, read).await?;

    let upload =
        UploadFileInput::document("./report.pdf", "report.pdf").with_mime_type("application/pdf");
    api.upload_file(&token, upload).await?;

    let _me = result.user;
    Ok(())
}
```

The SDK defaults to the `rust-sdk` client identity. Applications should pass
their own `ClientIdentity` so Inline can distinguish CLI, bridge, bot, agent,
and app traffic.

Use `inline_sdk::proto` for generated protobuf request and response types.
Realtime request inputs implement `RpcRequest`, so prefer
`RealtimeClient::call(proto::SomeInput { ... })` for normal RPCs. The lower
level `invoke(method, input)` remains available for advanced protocol work.
For concurrent RPCs and pushed updates on one WebSocket, use
`connect_session()`. Multiplexed sessions have per-RPC timeouts, heartbeat
deadlines, a bounded command queue, and a configurable
`max_in_flight_rpcs(...)` limit.

The SDK uses the standard Rust `log` facade and never initializes a logger.
Parent applications can opt in with `env_logger`, `tracing-log`, `android_logger`,
`oslog`, or any other `log` implementation. SDK logs avoid bearer tokens, auth
challenges, request bodies, response bodies, local file paths, and URL query
strings. Debug output for token-bearing results and URL-bearing builders/errors
redacts credentials, tokens, query strings, and local upload paths.

## Error handling

SDK error enums are non-exhaustive. Match the variants you want to handle
specifically and keep a fallback arm so applications continue compiling when
future SDK versions add more precise error cases.

The SDK keeps transport and convenience helpers here; durable cache, sync
state, and higher-level update handling belong in the `inline-client` crate.

## Publishing

Publish `inline-protocol` before `inline-sdk` for the same version. The SDK
depends on the matching protocol crate version.
