# inline-client

Stateful Rust client foundation for Inline.

This crate sits above `inline-sdk`. The SDK owns lower-level API, upload, and
realtime RPC helpers. `inline-client` is the long-term TDLib-style client layer:
auth/session lifecycle, realtime reconnect, update ordering, local cache, sync
cursors, pending transactions, idempotent sends, and committed client events.

The first public surface is intentionally small. It defines shared vocabulary
for hosts such as agents, CLI, bots, servers, native app bindings, and bridge
adapters:

- native peer, dialog, history, participant, message, and mutation records
- typed async `InlineClient` handle plus single-owner `ClientRunner`
- bounded command/event queues and in-flight backend request concurrency
- backend and store boundaries
- in-memory backend/store for client tests and host adapter tests
- SQLite store for sessions, sync journals/cursors, dialogs, users, spaces,
  memberships, messages, tombstones, reactions, read state, and transactions
- SDK-backed production backend using one multiplexed realtime RPC/event session
- realtime connector boundary with SDK and fake connector implementations
- host-provided external IDs for idempotency
- Inline random IDs and transaction identity
- client status and redacted error categories
- committed client events
- lossless vs best-effort event classification

Design rules:

- keep `inline-protocol`, `inline-sdk`, and `inline-client` as separate layers
- keep host-specific behavior out of the Rust client core
- expose a small facade over an internal async client actor
- use bounded command and event queues so overload becomes visible backpressure
- emit committed state events after durable update application
- classify realtime updates as lossless or best-effort before applying cache
  policy
- keep live reads and cached reads explicit: a failed live request is never
  reported as a successful cached response
- advance a cold bucket cursor only after rebuilding its authoritative current
  account, space-membership, or complete chat state
- keep local storage pluggable so CLI, agents, desktop, and mobile clients can
  share the same sync model without sharing filesystem assumptions
- use the standard Rust `log` facade in library code and leave logger
  initialization to parent binaries
- redact tokens, message bodies, captions, local paths, and auth-sensitive
  fields from public debug output

`inline-client` is pre-1.0 and its public API may still evolve. The runtime
routes auth/session lifecycle, live and cached dialogs/history, durable
reconciliation snapshots, participant mutations, chat metadata/deletion,
DM/thread/reply-thread creation, text/media sends, edits, message deletion,
reactions, read and marked-unread state, and typing through a backend trait.

The SDK backend owns a long-lived multiplexed realtime connection, heartbeat
and RPC timeouts, reconnect-triggered catch-up, InlineKit-compatible bucket
discovery/gap recovery, bounded bucket concurrency, and a write-ahead sync
journal so a crash cannot advance a bucket cursor past unapplied state. It
persists lossless state before emitting client events and exposes cached reads
for consumers that need to reconcile without causing network bursts. Logout
attempts to revoke the active Inline server session before clearing all local
account state.

Message sends expose their durable transaction state. Retriable or uncertain
stored sends are reconciled by reissuing the same server-idempotent random ID;
terminal failures are returned explicitly instead of masquerading as pending
messages.

Host-only protocol envelopes, HTTP/WebSocket routes, process flags, Matrix
projection, and deployment behavior remain outside this crate. Production
consumers should take the single bounded lossless event receiver and recover a
lagged host-side delivery stream from `account_state`, `chat_state`, cached
dialogs, and cached history. The built-in SQLite store protects credentials
only with filesystem permissions; hosts that require encrypted-at-rest session
storage should provide a `ClientStore` implementation backed by their platform
keychain or secret store.
