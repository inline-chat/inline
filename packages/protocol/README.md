# @inline-chat/protocol

Inline's public protocol package. It contains the generated Inline Schema and the portable Inline Protocol v1 secure-transport implementation used by Realtime V3.

Inline Protocol v1 is inspired by and byte-compatible with MTProto 2.0 at the secure-transport layer. It uses Inline endpoints, RSA key rings, authorization state, and application constructors; it does not connect to Telegram.

## Source of Truth

- Proto definitions live in `proto/` at the repo root.
- `core.ts` is generated from those proto files.
- `secure/` owns the audited carrier, handshake, encrypted-record, key-binding, reliability, clock, and server-session primitives.

## Install

```bash
bun add @inline-chat/protocol
```

## Exports

- `@inline-chat/protocol`
- `@inline-chat/protocol/core`
- `@inline-chat/protocol/client`
- `@inline-chat/protocol/server`
- `@inline-chat/protocol/carrier`
- `@inline-chat/protocol/schema`
- `@inline-chat/protocol/secure`
- `@inline-chat/protocol/vectors`

## Regenerate

From repo root:

```bash
bun run generate:proto
```

Do not manually edit generated schema files. Secure-transport changes require the cross-language vectors and security review described in the Inline Protocol specification.
