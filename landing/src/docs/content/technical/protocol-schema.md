---
title: "Protocol Schema"
description: "Realtime Protocol Buffer schema and generated packages."
---

- [`proto/core.proto`](https://github.com/inline-chat/inline/blob/main/proto/core.proto): methods, results, objects, and updates.
- [`@inline-chat/protocol`](https://github.com/inline-chat/inline/tree/main/packages/protocol): TypeScript schema and transport.
- [`inline-protocol`](https://github.com/inline-chat/inline/tree/main/crates/protocol): Rust schema and protocol.

Install TypeScript:

```bash
npm install @inline-chat/protocol
```

Install Rust:

```bash
cargo add inline-protocol
```

`Method` selects the matching `RpcCall` input. Unknown fields must remain forward-compatible. Unknown durable updates still require [sequence coverage](/docs/technical/sync#cursor) before cursor advancement.
