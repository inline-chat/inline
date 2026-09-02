# Realtime V3 over Inline Protocol v1

Status: normative application and transport overview for the current implementation. Realtime V3 is the application contract; Inline Protocol v1 is its secure, carrier-independent transport; Inline Schema is its Protocol Buffers application encoding.

Inline Protocol v1 is inspired by and byte-compatible with the relevant MTProto 2.0 secure-transport construction. Inline endpoints, trust roots, authorization state, application constructors, and product RPCs are distinct. MTProto 1.0 compatibility machinery is excluded except for the isolated temporary-key binding encoding required by MTProto 2.0.

## Security contract

- TLS and WebSocket provide reachability, not confidentiality, integrity, replay protection, or server authentication.
- The RSA_PAD/DH handshake validates the pinned server key, nonces, safe prime/generator/public values, transcript hashes, and DH confirmation before accepting an authorization key.
- Permanent authorization keys identify device authorization. Bound temporary keys carry ordinary RPCs and provide forward-secrecy rotation. Primary keys are never transmitted.
- Every post-handshake message uses the MTProto 2.0 KDF, AES-IGE record protection, direction checks, session/salt/message-ID/sequence validation, and persistent replay/result handling.
- Inline Protocol owns message IDs, containers, ACKs, resend/state recovery, cached results, gzip bounds, clock synchronization, and `bad_msg_notification` recovery independently of WebSocket.

Release clients pin the same overlapping production RSA verification ring, currently fingerprints `-8339382514522710386` and `-3957383261870667958`. Apple and the high-level TypeScript SDK use it by default; Rust publishes the validated ring for SDK/CLI owners; low-level/custom-server callers retain an explicit override. A production server validates the complete ordered public ring against that canonical artifact before its listener becomes ready. TLS endpoints never replace this ring dynamically. Only plaintext local Debug sockets may resolve process-local development keys from their matching verification endpoint; custom TypeScript/Rust development callers must pass that fetched local ring explicitly rather than weakening their production defaults.

## Application boundary

Unauthenticated permanent-key sessions may invoke only native login and required protocol control traffic. Unbound temporary keys may bind and exchange required control traffic. Bound temporary keys may invoke authenticated `RpcCall` methods. The server terminates Inline Protocol before dispatch so feature handlers receive the same typed user/session context regardless of Realtime V2 or V3.

Protocol Buffers are not hashed by re-encoding typed values. The exact received application bytes are the cryptographic payload. Security-relevant dispatch parses once with strict size/oneof/state rules; cross-language conformance is semantic for alternate valid protobuf encodings.

Authenticated product operations are typed RPCs, not HTTP requests wrapped inside encryption. Realtime V2 may carry the same RPC constructors during rollout, but the application handler and client state owner remain singular. A disconnected or unauthorized RPC fails explicitly and never falls back to a bearer endpoint.

The first migration tranche adds native create/delete/leave-space, connector configuration, external-task creation, device unregister, logout, and resumable-upload methods. Existing schema methods remain canonical for users, chats, history, messages, reactions, profile/avatar changes, sessions, push registration, and connector discovery/OAuth preparation.

## Request outcomes and replay

Every client and server owner uses the same semantic vocabulary. These are lifecycle states, not a new protobuf enum:

| Outcome | Meaning |
| --- | --- |
| `notSent` | Rejected before carrier dispatch; no execution claim is made. |
| `accepted` | Authenticated admission or local carrier dispatch was observed; diagnostic only, never user-visible success. |
| `confirmed(result)` | A matching authenticated result or error was received. |
| `commitUnknown` | Execution may have begun but no authoritative result arrived. This is not a definitive failure and is not automatically replayed. |
| `reconciled(state)` | A sequenced update or authoritative query established the resulting state. |
| `rejectedBeforeExecution` | The owner proved that execution did not begin, for example a local capacity rejection. |

A 30-second server application deadline ends only the caller's wait. If admission or a connection-local ordering lane proves application execution never began, the server completes replay with RPC 503/`rejectedBeforeExecution`; the exact retry returns that cached rejection. Once execution begins, the deadline returns RPC 504/`commitUnknown`. Actual handler settlement remains owned by the session and host: replay completion, `invokeAfter` release, per-session/global execution capacity, and the normal shutdown drain all wait for that settlement; the outer production shutdown deadline may still terminate the process. A duplicate remains in-flight until the actual result is known. Client cancellation and `rpc_drop_answer` stop interest in the response; they do not assert that the server stopped, suppress authoritative updates, or turn a running request into a completed replay result. Transport replay protection and cached results do not provide application idempotency across a new request/session identity.

Replay rows are never reclaimed into a second execution when their retention timestamp passes. Completed results are retained for ten minutes and deleted by one bounded, indexed cleanup owner. Expired in-flight claims are deliberately retained until their actual handler settles, because deleting one without a durable execution-owner fence would make the commit outcome ambiguous.

Automatic reconnect replay is restricted to proven queries or calls carrying the required stable identity. All other mutations surface `commitUnknown` after dispatch and reconcile through an update/query or a deliberate retry that reuses the same application identity. The exhaustive method contract is [Realtime V3 RPC semantics](./realtime-v3-rpc-semantics.md).

Application ordering remains narrow. Same-entity lanes serialize selected non-commutative chat, space, and account-setting mutations within one server connection while unrelated entities remain concurrent. Cross-connection correctness belongs to handler database transactions and row locks; the connection-local lane is not a global lock.

`updateSession` updates metadata owned by the authenticated current session. `updateDialogArchived` changes one dialog's archive boolean and returns the ordinary update stream. Telegram models archive as folder ID 1 and supports batch `folders.editPeerFolders`; Inline deliberately does not copy that layer because Main and Archive are product states here, not general-purpose folders. A future folders feature requires a separate contract.

Public authentication and invite bootstrap, OAuth browser redirects, CDN reads, and Bot API traffic remain HTTP by design. These paths never receive permanent/temporary authorization keys or authorize an Inline Protocol session.

## Carrier profile

The first carrier is binary WebSocket at `/realtime/v3`, with WebSocket compression disabled. The core uses Telegram-compatible obfuscated abridged framing and quick ACK semantics. HTTP status, TLS identity, cookies, bearer tokens, and text frames never authorize V3 traffic.

### Beta compatibility boundary

For beta, the handshake factorizer accepts the current Inline challenge form of `pq`: an unsigned big-endian value below `2^63`; the Swift and Rust clients additionally reject an encoded value longer than eight bytes. (The current Inline challenge is eight bytes.) This is an implementation restriction, not a new wire rule or an MTProto 2.0 requirement. The fixed challenge emitted by the current Inline server fits it, so this does not change Inline-to-Inline beta behavior.

The target remains 100% MTProto 2.0 compatibility for the secure carrier, except for machinery that exists only for MTProto 1.0 compatibility. Removing this beta-only bound requires coordinated lossless arbitrary-precision factorization in all three clients, cross-language positive and negative vectors, and cryptographic review. “Carrier compatibility” covers the secure transport construction and handshake only; it does not mean Telegram endpoint/API integration or an Inline-specific cryptographic derivation.

## Native authentication

Native email/phone challenge and completion run inside encrypted permanent-key RPCs. Challenges bind the permanent key, normalized identifier, delivery method, and client metadata; are short-lived, attempt-bounded, rate-limited, and consumed once. Successful completion creates/reuses the normal Inline user and account session, binds it to the permanent authorization key, and returns no bearer token.

## Native resumable uploads

Realtime V3 defines `createUpload`, `saveUploadPart`, `getUploadState`, `finishUpload`, and `cancelUpload`. Upload bytes remain inside encrypted Inline Protocol RPCs; no PUT URL, capability, bearer token, or object-store identifier crosses the API.

The deprecated HTTP-upload request/result constructors are reserved wire history only. Servers do not dispatch them and do not expose the former `/v3/uploads/:id` PUT route.

- Sources are immutable and committed by whole-file SHA-256.
- The server negotiates 512 KiB parts. Non-final parts are exact-sized and up to 1,000 parts cover the current 500 MiB outer limit.
- Admission also enforces the existing media limits before reserving quota: photos 40,000,000 bytes, videos/documents 200,000,000 bytes, and voice 20,000,000 bytes.
- Parts may arrive out of order. Identical retries succeed; conflicting bytes at an accepted index fail. Progress is server-accepted bytes.
- Clients reconcile accepted indices after lost responses, reconnects, restarts, or temporary-key rotation.
- Apple clients first copy each source into an owner-scoped immutable app-group/Application Support staging file and durably record server-accepted progress. The server remains authoritative after restart; local progress is never trusted to skip a part.
- Finish uses a reclaimable processing lease, verifies ordered length and SHA-256, invokes existing media processing, and caches the typed `Photo`, `Video`, `Document`, or `Voice` result.
- Clients clamp authenticated `processing.retry_after_seconds` hints to 1–30 seconds so a malformed server value cannot stall an upload owner indefinitely.
- Jobs bind to user, account session, and permanent key. Revocation/logout prevents further access. Idle expiry is 24 hours and hard expiry is seven days.
- Client scheduling permits at most three globally and two per upload in flight with fair round-robin selection. A carrier may apply a lower bound while preserving the same RPC/state semantics; these are private tuning values, not feature API.

Feature code sees only a high-level media upload operation with progress, cancellation, and typed completion. Realtime V2 may temporarily carry the same typed RPCs behind the transport adapter; user HTTP upload APIs are not the fallback. Existing CDN downloads and Bot API uploads retain their existing paths.

Client edge behavior is normative: iOS suspension pauses transfer; a killed Share Extension does not silently send later; logout/account switch invalidates owner-scoped staging; lost responses reconcile from server state; an immutable staged source cannot be replaced beneath an upload; and cancellation racing finalization resolves to one server-authoritative terminal state.

Apple and TypeScript upload owners send `cancelUpload` during deliberate cancellation. The beta Rust/CLI owner currently treats future cancellation as “stop waiting”: server staging remains resumable until normal expiry/cleanup. It must not claim remote cancellation until a dedicated Rust cancellation API owns that RPC.

Finalization ownership is fenced by `(upload row, processing status, lock token)`. The owner renews its lease, verifies the fence before staging reads and permanent publication, and is the only attempt allowed to complete/fail or clean staging. Cancellation of an actively processing upload returns processing/non-cancelable and never removes its parts. Expiry cleanup first claims its own conditional fence.

Permanent media publication is deterministic and schema-free. The first finalization claim reserves an upload-derived `file_unique_id`; every retry writes the same object path, and one PostgreSQL transaction reconciles or creates the canonical file/media rows and completes the still-fenced upload row. A stale fence cannot publish database state. If the transaction commits but its result is lost, the next `finishUpload` or `getUploadState` returns the cached canonical result without creating another media entity. No publication/outbox state owner or migration is required for duplicate prevention.

Staging-object lifecycle expiry remains a deployment/configuration gate. Database cleanup conditionally removes known incomplete deterministic publications and staging parts, while the object store must independently expire abandoned `inline-upload-parts/v1/` objects so database loss cannot retain staged bytes forever. Completed and incomplete deterministic publication objects share a permanent prefix and must not receive a blanket TTL; absolute cross-store orphan accounting would require a separately approved durable publication/outbox owner and is deferred.

## Opt-in encrypted range downloads

`GET_FILE_PART` is V3-only and repeat-safe. It is additive: media encoders retain
all CDN URLs and also provide optional `file_unique_id` on video, document, voice,
and each stored photo size. Stripped embedded photo bytes need no file request.

```text
getFilePart({file_unique_id, offset, limit, message?: {chat_id, message_id}})
  -> {offset, total_size, data, sha256}
```

`limit` is 1..524288 bytes; `offset` is a byte offset, at most the file size.
The last part is short; exact EOF returns empty bytes and its SHA-256. Every
request checks file ownership or current access to the exact message and its
file reference, including media thumbnails, URL previews, and current rich-image
references. Unknown and inaccessible IDs share a bad-request result. An arbitrary
file ID, chat ID, or media ID is not an authorization capability.

The server reads only the requested R2 range using `S3File.slice`, with an exact
length check and a cancellable stream. Admission is bounded to eight active reads
per account session and 64 per process, held until work settles. No signed URL,
storage path, provider credential, or download session is returned or created.

`NativeDownloadClient` / `rpcDownloadTransport` from `@inline-chat/protocol/downloads`
provide an opt-in ordered async iterator, three buffered/in-flight parts by
default (configurable 1..8), chunk geometry/digest validation, and explicit resume
offsets. The transport must honor AbortSignal and bound individual RPC duration;
early iterator return aborts and drains outstanding work. Source/RPC upload
adapters likewise receive optional AbortSignals. Adapters must forward them into
their existing request owner, not detach an unresolved request to free a slot.

```ts
// call(method, input, signal) is the host's cancellable, deadline-bounded
// V3 RPC adapter; classify GET_FILE_PART as a replay-safe query there.
const transport = rpcDownloadTransport(call)
for await (const part of new NativeDownloadClient(transport).download({
  fileUniqueId, message: { chatId, messageId }, offset: durableOffset, signal,
})) {
  await sink.write(part.data)
  durableOffset = part.offset + BigInt(part.data.length)
}
```

Use the adapter's existing read-only reconnect/deadline policy for transient
transport failures; the helper does not blindly retry permission errors or switch
to a CDN. Persist the checkpoint only after the sink commits bytes. The file ID
identifies an immutable representation; per-part hashes protect range assembly,
not independent end-to-end verification against a trusted whole-file digest.
Avatars without message/owner provenance and legacy records without an object
path or trustworthy positive size are outside this first slice. Retain the CDN
path for those and for old servers/clients. Existing download behavior remains the default.

Apple also exposes an opt-in `NativeFileDownloader` backed by
`NativeFilePartFetching`. It writes validated ranges to a new caller-selected
file with at most two pending/buffered parts; failure/cancellation removes its
partial file, and exclusive creation prevents overwriting existing files.
The default size ceiling is 500 MiB. Progress runs off the main actor. Use an
already-connected `RealtimeV2` or a request-scoped `RealtimeDirectSession` configured
with an authenticated V3 transport (a legacy transport cannot use this RPC).
The Apple Settings > Experimental > Native File Downloads preference defaults off.
When enabled, only message document downloads use native ranges, resolving the
exact file identity with one `getMessages` request first. Other media and downloads
without message context remain on CDN. Cancellation, progress and logout share the
existing FileDownloader owner. Errors remain visible; turning the preference off
restores CDN for the next attempt. Cached local files bypass either network path.

```swift
let fileURL = try await NativeFileDownloader().download(
  fileUniqueID: id, message: locator, to: destination
)
```

## Storage boundary and future encryption

PostgreSQL stores upload manifests/state/leases/results; an `UploadPartStore` stores durable staging objects; a `MediaFinalizer` consumes verified ordered plaintext and creates existing media records. Provider keys and object locations never enter schema or app code.

Future object-at-rest encryption belongs inside staging and final storage adapters. It must preserve the plaintext-stream interface and plaintext integrity commitment, so RPCs, resumption, feature APIs, and clients do not change when storage ciphertext is introduced.

## Update durability and repair

One update collector is installed before a connection becomes eligible for normal fanout. Each existing user, space, or chat bucket owns:

```text
persisted cursor + bounded pending updates + live/repairing/reseeding/degraded state + connection generation
```

For a received sequence range, clients apply the contiguous next sequence, ignore stale/duplicate sequences, and retain a bounded gap target while one authoritative `getUpdates` repair runs. Apple/Rust may buffer the unsafe live copy; TypeScript deliberately discards that copy and re-reads it from the durable bucket page rather than adding a second buffer owner. Same-bucket live application is postponed during repair while unrelated buckets remain concurrent. Overflow clears unsafe payload copies, records the catch-up target, and never silently continues. Session reset, restart, or temporary-key replacement must confirm convergence before the sync owner reports `live`; clients may keep rendering the last durable state with an explicit syncing/degraded classification instead of blocking the whole account UI.

Durable model projection and cursor advancement are one commit where the client owns one database. Apple commits GRDB projections plus the bucket cursor in one transaction. Its UserDefaults-backed settings projection is application-first and idempotent, so a crash may replay it but cannot skip it. SDK hosts advance catch-up cursors only after their awaited consumer acknowledges application. Rust/CLI transport lag is observable and recovery remains with the state/cursor owner.

The update collector is installed before startup/reconnect discovery. `GET_UPDATES_STATE` emits targeted `chatHasNewUpdates` and `spaceHasNewUpdates` events for changed resource buckets; clients fetch only those buckets through their existing single-flight owner, plus the independent user bucket. Clients must not enumerate every persisted chat or space cursor on reconnect. A socket-open event is not proof of convergence, and the shared discovery checkpoint must not advance past a targeted bucket whose update application or cursor commit failed.

Discovery ordering is semantic, not timer-based. The server queues every hint caused by one `GET_UPDATES_STATE` call before that call's RPC result on the same authenticated stream. Before completing the RPC to its sync owner, a client collector hands all preceding update batches to that existing owner so it can register the round's targets. The result closes target collection for that round; later live hints belong to later work and cannot satisfy or enlarge the old checkpoint. This handoff is distinct from downstream UI acknowledgement: each targeted bucket still owns application, durable cursor commit, and only then release of the shared checkpoint. Implementations must not substitute an event-loop delay, queue snapshot taken outside the receive owner, or unrelated future hint for this boundary.

Incremental pages contain at most 100 logical updates. The server owns a 10,000-logical-update replay ceiling. A gap through 10,000 is pagination; a larger gap returns `TOO_LONG`, whose `seq` is the authoritative replacement target and never a cursor. Every bucket then uses its existing snapshot owner: user first captures the current user checkpoint through `GET_UPDATES_STATE` with no date, then fetches `GET_CHATS`, `GET_ME`, and settings; space uses the small `GET_SPACE` result (`Space.seq`, the authenticated user's `membership`, and settings); chat uses `GET_CHAT` plus a bounded latest history read. A repair validates identity and checkpoint coverage, preserves useful cached message rows, applies the replacement projection, and commits projection plus cursor together. Failure preserves the prior cursor and degrades only that bucket. There is no cold-50 path, local 1,000-update slicing, or 5/14-day lookback.

Sequenced user/space/chat bucket records are durable and recoverable through `getUpdates`. A client that does not project a known or future update kind treats it as an application no-op only inside a page whose complete `updates + skipped_sequences` coverage has been authenticated; it then advances the page cursor so older clients cannot be stranded by schema growth. A malformed update kind that the client claims to project remains an apply failure and cannot silently advance. Server updates emitted by the explicitly transient presence/compose owner, direct `GridEvent`, and `BotEvent` are ephemeral/lossy; Grid snapshots repair current media state, while bot interactions have no history contract.

Unknown-page accounting is a forward-progress guarantee, not a capability guarantee. A new durable constructor may be emitted only after the minimum compatible client versions can account for unknown page entries. The canonical access and history-clear constructors are part of the current Sync V3 contract; future constructors still require explicit client-compatibility review. An older client may safely advance over content it cannot project, but it cannot materialize that content until an authoritative snapshot or a compatible client version supplies the projection.

### Content-derived bucket catalog

The server emits the canonical access-transition and per-chat history-clear families described below. Legacy constructors remain decodable for already-persisted update rows, but new mutations do not emit them and the server never dual-writes both families.

Updates do not carry a bucket field. Ownership is inferred from their content and kept consistent across server and clients:

| Bucket | Durable content |
| --- | --- |
| User | account/settings/profile changes; dialog open/archive/follow/read/unread state; space join/leave; top-level `userAddedToChat` / `userRemovedFromChat` access transitions |
| Space | membership and space-settings changes |
| Chat | messages, attachments, pins, chat metadata/visibility, participants/groups, chat move/delete, and scoped clear-history effects |

Reactions and new-message notifications are ephemeral. Message-action invoke/answer remain a documented legacy exception until their RPC-callback migration; new durable producers must not copy them. Subthreads are discoverable from their parent chat and emit no durable user access event on creation, including for initial explicit participants. Their chat bucket becomes relevant through the existing follow/open dialog path. Optional `group` / `group_id` on a top-level access event is provenance, not another access constructor.

### Message-history coverage

Realtime sequence continuity and history continuity are separate. Apple persists merged inclusive message-ID holes and never treats a chat-list top message, `GET_CHAT`, or `GET_MESSAGES` as contiguous history proof. Only a successfully applied `GET_CHAT_HISTORY` response subtracts its proven numeric interval. Missing `AROUND` anchors are valid coordinates: history is selected below, at, and above the numeric ID without requiring the anchor row to exist. Cached rows render immediately; a dedicated repair owner fills holes as the visible window approaches them, without destructive chat replacement.

## Resource limits and overload behavior

Limits live with existing owners and reject before execution, close with an overload classification, or force authoritative update repair:

| Owner | Default limit | Overflow |
| --- | --- | --- |
| Server V3 handshake | 256 global / 8 per IP concurrently; 4,096 global / 60 per IP starts per minute | HTTP 503 before WebSocket upgrade |
| Server socket inbound | 32 copied frames; 32 MiB | WebSocket 1013 |
| Server socket outbound | 4,096 records; 32 MiB | WebSocket 1013 |
| Secure session / process | 64 active RPCs per connection and per account authority; 512 globally; 16 MiB packet/result-update budget per request; 256 MiB retained update bytes globally | request-local 503 before execution, or 504/commit-unknown if update capacity is exhausted after execution starts |
| Apple transaction owner | 32 active ordinary transactions; queued ephemeral work expires after its transaction-defined age (five seconds by default) | durable work waits locally; ephemeral work coalesces/expires and never crosses reconnect |
| Apple writer / update pipe | 256 items; 16 MiB each owner | explicit transport failure or catch-up |
| Apple bucket repair buffer | 4,096 updates; 16 MiB | clear buffer and force authoritative repair |
| TypeScript RPC / update owners | 64 pending RPCs; 256 events/updates; 8 MiB event/update bytes | capacity error or reconnect/catch-up |
| Rust session / update owners | 64 pending RPCs; 256 updates; 8 MiB pending update bytes | capacity/lag error; no mutation replay |
| Native uploads | 20 active and 2 GiB reserved bytes per session; 4 finalizers | reject before new work |

These are implementation defaults, not protobuf schema promises. Changes require load evidence and release notes because clients use overload classification to choose retry versus repair.

### Timeout and cancellation ownership

The server application deadline is 30 seconds, but it bounds the caller's response wait rather than pretending to cancel arbitrary handler code. The request keeps its application/replay permit until the handler actually settles; a pre-entry deadline is 503/`rejectedBeforeExecution`, while a post-entry deadline is 504/`commitUnknown`. Deployment shutdown has its own outer drain/force-close deadline.

Client wait guards are deliberately later or independently scoped: Apple V3 application requests use 45 seconds and direct calls default to 15 seconds; the TypeScript high-level client defaults to 30 seconds while its low-level V3 request owner uses 60 seconds; Rust defaults to 60 seconds. A client guard never converts a dispatched mutation into a definitive failure: queries may retry under their declared replay policy, while mutations after admission surface `commitUnknown`. Cancellation before admission is known-not-sent; cancellation after admission normally stops only the caller's interest.

The Share Extension's 15-second connection admission and 12-second message wait do not bound a file transfer. Its upload coordinator assigns 60 seconds to each create/part/finalize RPC and 15 seconds to state reconciliation; an earlier shared carrier/server deadline becomes the normal lost-result reconciliation path rather than a whole-upload failure. Only best-effort terminal cancellation cleanup is capped at five seconds. Temporary-key rotation stops admitting new RPCs at the authenticated boundary, lets already-admitted bounded requests settle, and then reconnects through the existing session owner; it is not a high-level multipart-operation lease.

## Authorization generations and logout

Authorization is scoped by account, permanent authorization generation, temporary authorization generation, transport generation, and the credential owner. An ambiguous network failure does not invalidate a usable temporary key. Temporary keys are process-local on the server: when a new connection presents a key forgotten by a restart, the server uses the authorization-invalidated close classification so the client can prove its permanent authority and bind one replacement instead of retrying the stale key. Replacement otherwise follows authenticated rejection, known expiry, or permanent-key-authenticated verification; a replaced key invalidates only the transport generation that used it. If the permanent authority was revoked, replacement binding fails terminally.

The current temporary-key profile has a fixed 86,400-second lifetime. Clients rotate at the authenticated 80%-elapsed boundary (`expiresAt - 17,280` seconds), using the server clock established by the handshake and refreshed by authenticated server messages. A cached reconnect probes with `GetMe` before deciding whether the key is still below that boundary; a long-lived session stops admitting new RPCs at the boundary and lets its existing reconnect owner create and persist the replacement. This is a lifecycle policy over the existing authorization fields, not a new schema or authority owner.

Logout is distinct from disconnect. Persistent clients use marker-first destruction:

1. Persist that logout/destruction began.
2. Stop admitting ordinary application work.
3. Attempt remote revocation with a bounded wait.
4. Destroy permanent, temporary, pending-login, and owned bearer authority regardless of the remote result.
5. Clear the marker only after local deletion succeeds.
6. On restart, block authentication and finish local destruction before reconnect.

Server logout revokes the account session when its transaction commits. Other connections owned by that session close at revocation; the invoking V3 connection is preserved only long enough to encrypt a successful terminal result with its already-loaded temporary key, after which the protocol session is destroyed and the carrier closes. Requests that begin execution before revocation may finish; queued product RPCs revalidate authority before execution. Concurrent finalization or transport loss can hide the logout result, so callers must complete marker-first local credential deletion without depending on it. TypeScript requires a host-provided durable credential owner. CLI environment bearer authority is not owned by the CLI and remains active with an explicit diagnostic. Transport close/stop preserves stored credentials. Closing a started high-level `InlineSdkClient` permanently disposes that instance and its event stream; reconnect with a new client. Low-level transport stop remains reconnectable.

## Required conformance

TypeScript, Rust, and Swift consume the same frozen cryptographic vectors. Required gates cover handshake/record exact bytes, binding, reliability, replay across restart, clock correction, protobuf semantic interoperability, upload state encoding, integrity substitution, duplicate/conflicting parts, response loss, restart/reconnect, cancellation/finalization races, expiry/revocation, bounded resources, and fair production-sized transfers.

Production requires the shipped overlapping RSA ring to match the active server ring, plus overlapping KEK/auth-code key rings, rotation tooling, restart-safe migrations, public readiness/clock health, implementation-level independent cryptographic review, focused load/reconnect proof, and an explicit deployment approval. V2 remains available during rollout.

Rollout admission is independently drainable: stop accepting new V3 upgrades, drain active V3 connections, and leave V2 healthy. Rollback never changes the frozen secure construction or destroys client authority merely because one transport generation failed. Release provenance must bind source revision, generated protobuf artifacts, pinned overlapping public roots, binary identity, and the conformance results used for that artifact.

## Versioning

Changes to the secure byte-level construction require Inline Protocol v2. Application RPC/schema evolution that preserves the secure construction remains Realtime V3 with normal backward-compatible field/method additions. Replacing Protocol Buffers is deferred to Realtime V4 or another explicitly versioned contract.
