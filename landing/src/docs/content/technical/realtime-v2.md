---
title: "Realtime V2"
description: "Compatibility notes for Inline's bearer-token realtime API."
---

Realtime V2 is the bearer-token WebSocket carrier used by the current TypeScript and low-level Rust SDK quick starts.

## Endpoint

```text
wss://api.inline.chat/realtime
```

V2 accepts the normal Inline bearer token and carries typed Realtime RPCs and updates. It remains a compatibility path while Realtime V3 uses Inline Protocol authorization keys and `/realtime/v3`.

Use [Realtime API](/docs/realtime-api) for a working SDK example. Use [Realtime](/docs/technical/realtime) for the current protocol architecture and reliability model.
