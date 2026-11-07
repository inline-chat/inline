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
chat or download an account's complete message history. A user-bucket repair
also revalidates cached spaces with `getSpace`, so a lost self-removal cannot
resurrect workspace navigation. Normal space membership remains owned by its
independently repairable space bucket.

Live `dialogs()` discovery deduplicates source and cached space candidates and
checks at most eight `getSpace` self memberships per call. Each RPC has a two
second timeout and the RPC refresh has a five second budget, including cursor
contention. Cached store reads and local directory processing are outside that
network deadline.
A process-local rotating cursor shared by backend clones prevents the first
spaces from starving later candidates. Unattempted spaces remain pending; later
live dialog scans continue and retry failures. A transient refresh failure
records unknown access, while an explicit source denial records removed access
and keeps independently accessible chats. Removal tombstones survive transient
failures, cache upserts and restart. Cached `account_state()` never performs
network requests, and `space_access_complete` remains false: cached users,
spaces and memberships are not an authoritative directory or a permission
guarantee. Legacy rows have no authoritative structural descriptor until a
canonical source observation establishes one.

Source chat sequences are persisted atomically with their projections, so older
snapshots and queued sidecars cannot undo a newer move or detach after restart.
GetSpace responses and failure fallbacks compare the pre-request access revision;
account clear advances a durable generation and invalidates in-flight replies.
Accepted access, self identity, space and self membership commit atomically;
removal cleanup shares that transaction. Repairs check the generation captured
before their RPCs, then hold a shared store lifecycle lease across final local
writes and the cold cursor commit. Raw account clearing through any built-in
store clone takes the write lease, so it cannot split that final section.
No lifecycle lease spans a network request.
A replayed member Add or Join cannot clear a removal tombstone. Only events
from a proven matching space sync bucket advance the access space frontier;
user-bucket and unsequenced removals invalidate access without comparing clocks.
A fresh GetSpace membership proof can restore access at the same or a later
space frontier if its pre-request revision still matches. Thus a real
unsequenced eviction is honored immediately and a subsequent source request
can reconcile it without waiting for an unrelated sequence increment. GetChats preserves cached pin
IDs because its chat/dialog summaries do not contain a pin-ID snapshot.

Custom stores used with `SdkBackend` must implement the source-version and atomic
source-write and lifecycle-guard methods on `ClientStore`; their defaults return `Unsupported` rather
than applying unguarded authority.

Message sends expose their durable transaction state. Retriable or uncertain
stored sends are reconciled by reissuing the same server-idempotent random ID;
terminal failures are returned explicitly instead of masquerading as pending
messages.

Text sends, edits, and media captions accept default-empty `entities` in UTF-16
coordinates. The client checks signed ranges, overflow, and scalar boundaries
before authentication, transaction writes or uploads. Supported native styles,
links and typed mention/group/thread/command payloads reach the RPC unchanged;
unknown kinds and thread-title payloads that need a source space ID absent from
the record return `Unsupported`. Explicit entities can accompany
`parse_markdown`; the source remaps their raw-text ranges while parsing.
Incoming metadata and unknown entity records remain readable and unchanged.

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
