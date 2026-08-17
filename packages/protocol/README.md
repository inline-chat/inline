# @inline-chat/protocol

Inline's public protocol package. It contains the generated Inline Schema and the portable Inline Protocol v1 secure-transport implementation used by Realtime V3.

Inline Protocol v1 is inspired by and byte-compatible with MTProto 2.0 at the secure-transport layer. It uses Inline endpoints, RSA key rings, authorization state, and application constructors; it does not connect to Telegram.

## Source of Truth

- Proto definitions live in `proto/` at the repo root.
- `core.ts` is generated from those proto files.
- `secure/` owns the audited carrier, handshake, encrypted-record, key-binding, reliability, clock, and server-session primitives.
- [`docs/realtime-v3.md`](docs/realtime-v3.md) is the discoverable normative overview for the current security, authentication, reliability, native-upload, storage, compatibility, conformance, and versioning choices.

## Install

```bash
bun add @inline-chat/protocol
```

## Exports

- `@inline-chat/protocol`, `/core`, `/client`, and `/schema` preserve the generated Inline Schema compatibility surface. The generator owns `src/client.ts`; secure transport must never reuse that path.
- `@inline-chat/protocol/secure` exposes the portable cryptographic, carrier, handshake, reliability, and session primitives.
- `@inline-chat/protocol/carrier` is the client/server-neutral obfuscated abridged carrier surface, including Telegram-compatible quick ACK framing.
- `@inline-chat/protocol/server` exposes the server handshake and session engine.
- `@inline-chat/protocol/vectors` contains frozen cross-language conformance vectors.
- `@inline-chat/protocol/vectors/inline-protocol-v1.json` is the exact language-neutral corpus consumed by the TypeScript, Rust, and Swift tests. It includes deterministic permanent and temporary three-step DH transcripts, every random input, the derived authorization keys/IDs and salts, RSA_PAD intermediates, both record directions, and reliability/application objects.

## Regenerate

From repo root:

```bash
bun run generate:proto
cd packages/protocol && bun run generate:vectors
```

Do not manually edit generated schema files. Secure-transport changes require the cross-language vectors and security review described in the Inline Protocol specification.
