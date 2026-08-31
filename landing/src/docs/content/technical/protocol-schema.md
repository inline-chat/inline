---
title: "Protocol Schema"
description: "Protocol Buffer definitions and generated packages for Realtime RPCs and updates."
---

Inline Schema defines Realtime objects, methods, results, and updates.

`Method` selects the matching input in the `RpcCall` oneof. Read the corresponding result type and application error, rather than treating any received frame as success. Prefer generated SDK calls to assembling the enum and oneof by hand.

Fields added by a newer schema must not break older decoders. Unknown durable update kinds still require [authenticated sequence coverage](/docs/technical/sync#cursor-and-target) before a sync cursor advances.

- [`proto/core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto) — schema source.
- [`@inline-chat/protocol`](https://github.com/inline-chat/inline/tree/main/packages/protocol) — generated TypeScript schema and transport exports.
- [`inline-protocol`](https://github.com/inline-chat/inline/tree/main/crates/protocol) — generated Rust schema and protocol support.

```bash
npm install @inline-chat/protocol
```

```bash
cargo add inline-protocol
```

[Realtime transport](/docs/technical/realtime) · [RPC semantics](/docs/technical/rpc)
