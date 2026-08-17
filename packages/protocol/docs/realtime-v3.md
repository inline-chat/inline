# Realtime V3 over Inline Protocol v1

Status: normative application and transport overview for the current implementation. Realtime V3 is the application contract; Inline Protocol v1 is its secure, carrier-independent transport; Inline Schema is its Protocol Buffers application encoding.

Inline Protocol v1 is inspired by and byte-compatible with the relevant MTProto 2.0 secure-transport construction. Inline endpoints, trust roots, authorization state, application constructors, and product RPCs are distinct. MTProto 1.0 compatibility machinery is excluded except for the isolated temporary-key binding encoding required by MTProto 2.0.

## Security contract

- TLS and WebSocket provide reachability, not confidentiality, integrity, replay protection, or server authentication.
- The RSA_PAD/DH handshake validates the pinned server key, nonces, safe prime/generator/public values, transcript hashes, and DH confirmation before accepting an authorization key.
- Permanent authorization keys identify device authorization. Bound temporary keys carry ordinary RPCs and provide forward-secrecy rotation. Primary keys are never transmitted.
- Every post-handshake message uses the MTProto 2.0 KDF, AES-IGE record protection, direction checks, session/salt/message-ID/sequence validation, and persistent replay/result handling.
- Inline Protocol owns message IDs, containers, ACKs, resend/state recovery, cached results, gzip bounds, clock synchronization, and `bad_msg_notification` recovery independently of WebSocket.

## Application boundary

Unauthenticated permanent-key sessions may invoke only native login and required protocol control traffic. Unbound temporary keys may bind and exchange required control traffic. Bound temporary keys may invoke authenticated `RpcCall` methods. The server terminates Inline Protocol before dispatch so feature handlers receive the same typed user/session context regardless of Realtime V2 or V3.

Protocol Buffers are not hashed by re-encoding typed values. The exact received application bytes are the cryptographic payload. Security-relevant dispatch parses once with strict size/oneof/state rules; cross-language conformance is semantic for alternate valid protobuf encodings.

Authenticated product operations are typed RPCs, not HTTP requests wrapped inside encryption. Realtime V2 may carry the same RPC constructors during rollout, but the application handler and client state owner remain singular. A disconnected or unauthorized RPC fails explicitly and never falls back to a bearer endpoint.

The first migration tranche adds native create/delete/leave-space, connector configuration, external-task creation, device unregister, logout, and resumable-upload methods. Existing schema methods remain canonical for users, chats, history, messages, reactions, profile/avatar changes, sessions, push registration, and connector discovery/OAuth preparation.

`updateSession` updates metadata owned by the authenticated current session. `updateDialogArchived` changes one dialog's archive boolean and returns the ordinary update stream. Telegram models archive as folder ID 1 and supports batch `folders.editPeerFolders`; Inline deliberately does not copy that layer because Main and Archive are product states here, not general-purpose folders. A future folders feature requires a separate contract.

Public authentication and invite bootstrap, OAuth browser redirects, CDN reads, and Bot API traffic remain HTTP by design. These paths never receive permanent/temporary authorization keys or authorize an Inline Protocol session.

## Carrier profile

The first carrier is binary WebSocket at `/realtime/v3`, with WebSocket compression disabled. The core uses Telegram-compatible obfuscated abridged framing and quick ACK semantics. HTTP status, TLS identity, cookies, bearer tokens, and text frames never authorize V3 traffic.

## Native authentication

Native email/phone challenge and completion run inside encrypted permanent-key RPCs. Challenges bind the permanent key, normalized identifier, delivery method, and client metadata; are short-lived, attempt-bounded, rate-limited, and consumed once. Successful completion creates/reuses the normal Inline user and account session, binds it to the permanent authorization key, and returns no bearer token.

## Native resumable uploads

Realtime V3 defines `createUpload`, `saveUploadPart`, `getUploadState`, `finishUpload`, and `cancelUpload`. Upload bytes remain inside encrypted Inline Protocol RPCs; no PUT URL, capability, bearer token, or object-store identifier crosses the API.

The deprecated HTTP-upload request/result constructors are reserved wire history only. Servers do not dispatch them and do not expose the former `/v3/uploads/:id` PUT route.

- Sources are immutable and committed by whole-file SHA-256.
- The server negotiates 512 KiB parts. Non-final parts are exact-sized and up to 1,000 parts cover the current 500 MiB outer limit.
- Parts may arrive out of order. Identical retries succeed; conflicting bytes at an accepted index fail. Progress is server-accepted bytes.
- Clients reconcile accepted indices after lost responses, reconnects, restarts, or temporary-key rotation.
- Apple clients first copy each source into an owner-scoped immutable app-group/Application Support staging file and durably record server-accepted progress. The server remains authoritative after restart; local progress is never trusted to skip a part.
- Finish uses a reclaimable processing lease, verifies ordered length and SHA-256, invokes existing media processing, and caches the typed `Photo`, `Video`, `Document`, or `Voice` result.
- Jobs bind to user, account session, and permanent key. Revocation/logout prevents further access. Idle expiry is 24 hours and hard expiry is seven days.
- Client scheduling permits at most three globally and two per upload in flight with fair round-robin selection. A carrier may apply a lower bound while preserving the same RPC/state semantics; these are private tuning values, not feature API.

Feature code sees only a high-level media upload operation with progress, cancellation, and typed completion. Realtime V2 may temporarily carry the same typed RPCs behind the transport adapter; user HTTP upload APIs are not the fallback. CDN downloads and Bot API uploads remain outside this contract.

Client edge behavior is normative: iOS suspension pauses transfer; a killed Share Extension does not silently send later; logout/account switch invalidates owner-scoped staging; lost responses reconcile from server state; an immutable staged source cannot be replaced beneath an upload; and cancellation racing finalization resolves to one server-authoritative terminal state.

## Storage boundary and future encryption

PostgreSQL stores upload manifests/state/leases/results; an `UploadPartStore` stores durable staging objects; a `MediaFinalizer` consumes verified ordered plaintext and creates existing media records. Provider keys and object locations never enter schema or app code.

Future object-at-rest encryption belongs inside staging and final storage adapters. It must preserve the plaintext-stream interface and plaintext integrity commitment, so RPCs, resumption, feature APIs, and clients do not change when storage ciphertext is introduced.

## Required conformance

TypeScript, Rust, and Swift consume the same frozen cryptographic vectors. Required gates cover handshake/record exact bytes, binding, reliability, replay across restart, clock correction, protobuf semantic interoperability, upload state encoding, integrity substitution, duplicate/conflicting parts, response loss, restart/reconnect, cancellation/finalization races, expiry/revocation, bounded resources, and fair production-sized transfers.

Production requires real overlapping RSA/KEK/auth-code key rings, rotation tooling, restart-safe migrations, public readiness/clock health, implementation-level independent cryptographic review, focused load/reconnect proof, and an explicit deployment approval. V2 remains available during rollout.

## Versioning

Changes to the secure byte-level construction require Inline Protocol v2. Application RPC/schema evolution that preserves the secure construction remains Realtime V3 with normal backward-compatible field/method additions. Replacing Protocol Buffers is deferred to Realtime V4 or another explicitly versioned contract.
