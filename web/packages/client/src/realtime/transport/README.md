# Realtime transports

`ProtocolClient` speaks `ClientMessage` / `ServerProtocolMessage` over a `Transport` (`transport.ts`). Three implementations:

| File | What |
| --- | --- |
| `ws-transport.ts` | V2: protobuf frames over a plain WebSocket to `/realtime`. The default. |
| `v3-transport.ts` | V3: the same messages over the Inline Protocol V3 secure transport (`/realtime/v3`). |
| `negotiating-transport.ts` | Chooses V3 or V2 per connection attempt, falls back, honors the operator preference. |
| `mock-transport.ts` | Scripted transport for tests. |

## V3 pieces

- **Portable connection**: `@inline-chat/protocol/secure/connection` (`packages/protocol/src/secure/connection.ts`). A port of the SDK's `v3-connection.ts` with the socket, CSPRNG, gunzip, AES backend, timers and clock injected (`InlineProtocolRuntime`). Same handshake, temporary-key binding, rotation boundary, acknowledgements and containers, bad-message recovery and admission limits as the SDK. It imports nothing from Node or the DOM; `v3-portable.test.ts` walks its module graph and typechecks it for a worker with no Node types. The gunzip is allowed to be asynchronous; only `gzip_packed` records await it, so uncompressed records keep the SDK's synchronous dispatch order.
- **Browser runtime** (`v3-browser-runtime.ts`): native `WebSocket` with `binaryType = "arraybuffer"`, `crypto.getRandomValues`, `DecompressionStream("gzip")` with an output cap, and AES on `makeCachedPureAesBackend`. Close codes a script may not send (the connection's 1011 on a protocol failure) are sent as 1000.
- **AES**: WebCrypto cannot back the protocol. It has no ECB or IGE (records use AES-256-IGE), and its API is asynchronous while record and carrier code call AES synchronously; the carrier's AES-CTR is a byte stream that would need counter bookkeeping across async calls. So the browser uses pure JavaScript. The new cached backend expands each key once per record (and once per connection for the carrier) instead of once per 16-byte block; it is byte-identical to the reference and Node backends (tested). The AES backend is process-global in `packages/protocol` (`setAesBackend`), so a runtime's backend is installed globally when a connection opens.
- **Credentials** (`v3-credentials.ts`): `InlineProtocolKeyStore` with `get`, `set`, `erase` per account (user ID). `MemoryInlineProtocolKeyStore` keeps them for the life of the tab or worker and wipes key bytes on replace and erase. Record states: `staged` (permanent key stored before the request that binds it) and `bound`.
- **Session upgrade** (`v3-session-upgrade.ts`): `upgradeBearerSession` follows the Apple `LegacyProtocolUpgradeAttempt`: stage the permanent key, `authUpgradeSession` with the bearer inside the encrypted carrier, check the user, bind a temporary key, prove it with `getMe`, store as `bound`. `V3SessionUpgrader` runs it in the background after a V2 open: one attempt at a time, 20 s deadline, 5 minute quiet period, logs by category only.
- **Identity** (`v3-connection-init.ts`): `buildConnectionInit` adds client type `web`, client version, OS version, device ID, device name and time zone; the V3 transport strips the token. `browserClientIdentity` derives device name ("Chrome on macOS") and time zone (`Intl`). See "What the server reads" below.

### Mapping `ClientMessage` onto V3

`start()` is one attempt, like V2: `connecting`, then an authenticated connection (the cached temporary key after a ping probe, or a new temporary key bound to the stored permanent key and persisted), then `connected`. `ProtocolClient` then sends its `connectionInit`; the transport sends V3 `connection_init` and emits the answer as a `connectionOpen` server message, including `upgraded_session_transport`. So `ProtocolClient`, `ConnectionManager` and `RealtimeClient` work unchanged; the existing `Transport` interface carries V3 without changes.

- `rpcCall`: `send` resolves when the record is written; `rpcResult` / `rpcError` arrive later with `reqMsgId` set to the message ID. A server rejection proved before execution (503) is redelivered twice after 1 s.
- `ping` → authenticated MTProto ping (ID is the nonce as signed 64-bit) → `pong`.
- Updates are held until the open is delivered, then forwarded as `message` events.
- A request that loses its answer after dispatch (timeout, close, commit outcome unknown) is treated as a lost connection: the connection closes and the transport emits `disconnected`. V2 has no per-request uncertainty, so this keeps the core's existing reconnect and resend path in charge.
- Rotation: at the authenticated rotation boundary admission closes (sends throw `not-connected`), in-flight requests drain, then the transport emits `disconnected("v3-temporary-key-rotation")`; the next `start()` mints a new temporary key without probing the retired one.
- Revocation (see "Security rules" below): a V3 close never erases anything. A rejected temporary key (server restart) is replaced once on the next start.

### Negotiation

Mirrors the Apple `NegotiatingRealtimeTransport`: V3 when the account has bound credentials and either has no bearer or the operator preference allows V3 and no fallback cooldown is running. A V3 start that fails or takes longer than 6 s falls back to V2 inside the same `start()` (bearer sessions only) and keeps V2 for 5 minutes. A V3 open with `upgraded_session_transport = LEGACY` retires V3 and emits `disconnected("transport_preference")`; the connection manager's next start selects V2. A V2 open records the preference and starts the optional upgrade. A retired child's events never reach the session.

## Security rules (security review, 2026-11-17)

The threat is someone who can read and write the TLS stream (a corporate TLS proxy, a stolen certificate). The carrier obfuscation does not stop them: its keys travel in the client's first frame. Records are what V3 authenticates; everything else is untrusted.

**Revocation.** The server signals revocation only with a WebSocket close (4401, `session_revoked_confirmed`), which is outside V3's cryptography. So:

- A revocation close on a live connection, or on the cached key's probe, is a recheck: the temporary key is retired, the transport reports `disconnected("v3-authorization-recheck")`, and the next start binds a new temporary key, which makes the server prove the revocation against the permanent key.
- If that binding is answered with a revocation close, the transport emits `connectionError(INVALID_AUTH)` and `disconnected("v3-session-revoked")`: the realtime client stops for re-authentication and erases nothing (`realtime.ts` erases only on `SESSION_REVOKED`).
- `SESSION_REVOKED` (sign-out and erase) is never derived from V3. It needs a revocation inside an authenticated record, which the server does not send today; until it does, a server-side revocation leaves the local replica and keys on the device until the user signs in again or out. V2's in-band `SESSION_REVOKED` is unchanged (V2 trusts TLS).

The Apple client still erases on the close (`RealtimeV3Connection.swift`, `terminationError`); the web client is deliberately stricter.

**Replay window** (in `@inline-chat/protocol/secure/connection`). Each server message ID is claimed in a 1,000-ID window per connection. A repeated ID, or one below the window, is dropped unprocessed and unacknowledged; reordering inside the window is accepted. The authenticated clock is re-sampled only on a new highest ID, and `new_session_created` changes the salt only from a newer record than the one that last set it. `bad_server_salt` answers a pending request by its exact ID and sequence number and is always followed.

**Clock and salt.** A cached key starts from the device clock, but records are not time-checked and rotation is not scheduled until the first authenticated record; the server's time corrections are followed (and a too-high first ID restarts the ID generator). Server records' salts are not checked. A device clock minutes or hours off still connects.

**Handshake work.** The `res_pq` challenge is unauthenticated. Before the shared handshake factors it, the connection requires 1 to 8 bytes, a value below 2^63, and a factor found within 2^19 Pollard-Brent steps; a prime fails the handshake in about 50 ms instead of blocking the worker for about 15 s.

**Errors and logs.** Errors leaving the connection are `InlineProtocolV3Error`s with fixed text and numeric codes: no decrypted fields, server error text, salts, nonces or keys. This directory logs fixed categories only.

**Fallback to V2.** The negotiating transport falls back from V3 to V2 only for a session that still holds a bearer, and only during a start: when the V3 start fails for any reason other than an authorization answer (a `connectionError`), or takes longer than 6 s. V2 is then kept for 5 minutes. A session without a bearer never uses V2. An active attacker can force this fallback for a bearer session (drop or stall the V3 socket), and a V2 open's `upgraded_session_transport = LEGACY`, which is TLS-only, can pin such a session to V2. That is accepted for now: the bearer that V2 carries is the same one the web app already sends over HTTPS (auth flows, HTTP API), so the fallback exposes nothing TLS does not already protect alone. Refusing V2 once V3 has worked would cost availability without protecting that bearer; the real fix is retiring the bearer after the upgrade (a server decision). An authorization answer on V3 (`INVALID_AUTH`) never falls back to V2. This matches the Apple `NegotiatingRealtimeTransport`.

## Key storage: recommendation

The permanent key is account authority, equivalent to the bearer the `auth` package already keeps. Recommended for the browser:

- IndexedDB (or OPFS beside the account's replica), one record per account, holding the permanent key and optionally the last temporary key (it expires in 24 h and saves a handshake on reload).
- Wrapped with AES-GCM under a **non-extractable** WebCrypto key generated per account and stored as a `CryptoKey` in IndexedDB.
- Erased on sign-out and on server revocation together with the replica (`security.md`): delete the record and the wrapping key; the in-memory store wipes its bytes.
- Owned by the worker that owns the connection, so one tab never races another over a temporary key.

Threat this addresses: key bytes leaking out of the origin through storage dumps, profile backups, diagnostics exports or logs. It does not protect against script running on the origin, which can use a non-extractable key as freely as the session itself; the content policy is the defense there (`security.md`). In Electron, wrap with the OS keychain through the `platform` interface instead. Nothing in this directory logs keys, tokens or server text: logs carry fixed categories only.

## Measured (Node 22, Apple silicon, in-process loopback: client and server on one thread)

| | pure (reference) | cached (browser default) | node:crypto |
| --- | --- | --- | --- |
| Permanent-key handshake, median | 43 ms | 49 ms | 67 ms |
| Temporary handshake + bind + first RPC, median | 41 ms | 46 ms | 59 ms |
| AES-IGE decrypt, 1 MiB | 60 ms | 6 ms | 22 ms |
| AES-CTR carrier, 1 MiB | 45 ms | 8 ms | 0.2 ms |

The handshake is dominated by BigInt RSA and Diffie-Hellman on both sides, not AES; the numbers include the server's half. Bulk traffic is where the cached backend matters (about 7 to 8 times faster than the reference). Not measured in a browser yet.

## Not verified

- A real browser or worker (only Node's `WebSocket`-shaped fake, Node's `DecompressionStream` and `crypto.getRandomValues`).
- A live server. The tests pair the connection with the real `InlineProtocolServerSession` from `@inline-chat/protocol` (the class `server/src/core/http/realtimeV3Host.ts` drives) with in-memory repositories; the host's admission, lanes, replay store, DB-backed key repository and `application.ts` dispatcher are not exercised.
- `V3Transport.stop()` does not cancel a connection that is still handshaking; it is discarded when it finishes or times out (30 s connect, 60 s request).
- Transfer-only connections and uploads over V3 (out of scope).

## What the server reads

- V2 `ConnectionInit`: token, build number, layer, `client_version`, `os_version`, `supports_working`. It ignores `client_type`, `device_id`, `device_name`, `time_zone`.
- V3 `connection_init`: only `supports_working` and `transfer_only`.
- Client type comes from the session at login. Time zone, device name, client and OS version can be stored on either transport with the `updateSession` RPC (`updateSessionInput(identity)`).

No wire, route or origin change is needed: the V3 endpoint does not check `Origin`, WebSockets are outside CORS, and `connect-src` already covers the API host. Development servers have their own RSA key ring, published at `GET /.well-known/inline-protocol` (`rsaPublicKeyRing`, `access-control-allow-origin: *`); production pins `@inline-chat/protocol/trust-roots/inline-protocol-production.json`.

## Switching the web core to V3 (edits outside this directory)

1. `realtime/realtime.ts`, `RealtimeClientOptions`: add `identity?: ClientIdentity` and `v3?: { runtime: InlineProtocolRuntime; rsaPublicKeys: readonly InlineProtocolPublicKey[]; keyStore: InlineProtocolKeyStore; upgrade?: boolean }`.
2. `getConnectionInit()`: return `buildConnectionInit({ token, buildNumber, layer, identity: this.identity })`.
3. Constructor, when `options.v3` is set and no `transport` is passed:
   ```ts
   const accountId = () => this.auth.getState().currentUserId // the signed-in user ID string, or null
   this.transport = new NegotiatingTransport({
     createV2: () => new WebSocketTransport({ url, logger: baseLogger.withScope("WebSocketTransport") }),
     createV3: () => new V3Transport({ url: v3RealtimeUrl(url), ...options.v3, accountId }),
     hasV3Credentials: async () => { const id = accountId(); return id != null && (await options.v3.keyStore.get(id))?.state === "bound" },
     hasBearer: () => this.auth.getToken() != null,
     upgrade: options.v3.upgrade ? new V3SessionUpgrader({ url: v3RealtimeUrl(url), ...options.v3,
       source: () => { const id = accountId(); const token = this.auth.getToken(); return id && token ? { userId: id, token } : null } }) : undefined,
   })
   ```
   V2 stays the default while `options.v3` is absent.
4. `stopSession()` (sign-out) and the session-revoked path: `await options.v3.keyStore.erase(userId)` before `auth.logout()`.
5. After `open`, optionally call `updateSession` with `updateSessionInput(identity)` once per session when the stored values differ.
6. The worker host builds the runtime with `createBrowserInlineProtocolRuntime()`, the production key ring, and a persistent `InlineProtocolKeyStore` as recommended above.
