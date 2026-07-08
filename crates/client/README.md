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
- bounded command and event queues
- backend and store boundaries
- in-memory backend/store for client tests and host adapter tests
- SQLite store for durable sessions, dialogs, and message history
- SDK-backed backend skeleton for production transport/store integration
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
- keep local storage pluggable so CLI, agents, desktop, and mobile clients can
  share the same sync model without sharing filesystem assumptions
- use the standard Rust `log` facade in library code and leave logger
  initialization to parent binaries
- redact tokens, message bodies, captions, local paths, and auth-sensitive
  fields from public debug output

`inline-client` is still pre-1.0. The public API will grow toward a full
stateful Inline client. The runtime already routes connect, status, dialogs,
history, logout, auth code login, participants, text/media sends, edits,
deletes, reactions, read receipts, typing, member snapshots, and chat creation
through a backend trait. The SDK backend sends/verifies email/SMS codes,
persists sessions, opens DMs, creates threads/reply threads, and reads
dialogs/history/participants through a store trait; it can optionally perform a
realtime SDK handshake through a connector trait. Host-only protocol envelopes,
HTTP/WebSocket routes, process flags, and deployment behavior are owned by the
host adapter or app. SDK-backed text and media sends use Inline realtime/API
RPCs, persist transaction state, and record returned message rows when the
server includes them in the send result. Live inbound realtime sync is the next
production piece. The SQLite store is durable enough for beta restart/catch-up
work, but cache schema expansion for users, cursors, reactions, media, and
richer transaction retry/recovery is still expected.
