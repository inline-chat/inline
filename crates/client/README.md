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
- SQLite store for sessions, sync journals/cursors, a durable client-event
  outbox, dialogs, users, spaces, memberships, messages, tombstones, reactions,
  read state, and transactions
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
- advance a cold bucket cursor only after rebuilding the state owned by that
  bucket: account identity/deletions, space membership, or a chat snapshot plus
  its bounded recent-history window
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
journal so a crash cannot advance a bucket cursor past unapplied state. The
built-in sync path advertises its lossless schema revision as additive metadata,
requires explicit accounting for every advanced sequence, rejects conflicting
page envelopes regardless of revision, and treats realtime hints only as
catch-up targets. Warm gaps are committed one
validated page at a time, so very long gaps resume from durable progress rather
than replaying an entire in-memory batch. Incompatible pending journals are
discarded without cursor advance and refetched from the authoritative server.
Built-in stores commit each cursor change and its resulting lossless events in
one transaction. Lossless events remain in an outbox until the consumer
acknowledges their delivery, so a restart replays events whose host handoff may
not have completed. Custom stores that do not implement the outbox extension
fail before committing a cursor that produced lossless events. Cached reads are
available for consumers that need to reconcile without causing network bursts.
Use `DialogsOrder::StableChatId` for mutation-safe full-account reconciliation;
the default recent-activity order is intended for user-facing lists.
Live `getChats` results are visibility-filtered snapshots: they merge current
records into the durable store, but omission alone never tombstones a cached
dialog. Lossless deletion updates and explicit reconciliation tombstones own
chat deletion.
Logout attempts to revoke the active Inline server session before clearing all
local account state.

Cold chat repair intentionally fetches the current chat snapshot and the latest
50 messages, matching InlineKit's ownership boundary. Older history is paged by
normal history APIs and host checkpoints; a cold user bucket does not walk every
chat, download an account's complete message history, or fetch every space's
membership. Space membership remains owned by its independently repairable
space bucket.

Message sends expose their durable transaction state. Retriable or uncertain
stored sends are reconciled by reissuing the same server-idempotent random ID;
terminal failures are returned explicitly instead of masquerading as pending
messages.

Host-only protocol envelopes, HTTP/WebSocket routes, process flags, Matrix
projection, and deployment behavior remain outside this crate. Production
consumers should take the single bounded lossless event receiver. Use
`recv_delivery()` and call `LosslessEventDelivery::ack()` only after the event is
durable in the host. Dropping a delivery without a successful acknowledgement
releases its process-local claim for replay. The compatibility `recv()` method
attempts acknowledgement before it returns and is intended for consumers that
accept the legacy at-most-once host handoff. A host that has lost its own
delivery history can reconcile from `account_state`, `chat_state`, cached
dialogs, and cached history. The built-in
SQLite store protects credentials only with filesystem permissions; hosts that
require encrypted-at-rest session storage should provide a `ClientStore`
implementation backed by their platform keychain or secret store.
