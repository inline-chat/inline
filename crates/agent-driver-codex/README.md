# Inline Codex Agent Driver

Direct, structured integration with `codex app-server` for Inline's local
coding-agent bridge. The driver owns Codex process supervision, JSONL protocol
compatibility, and event normalization; it does not own Inline presentation.

The capability-gated session connection shares the driver's one JSON-RPC
reader. Attachment registers before `thread/resume`, then uses that response's
wire sequence and bounded thread snapshot as one atomic repair boundary. Frames
at or before the response are snapshot-covered; later user, assistant, plan,
command, file-change, and runtime-state events receive attachment-local
sequences. Codex provides no notification replay cursor, so disconnects, slow
consumers, and buffer gaps close the observer and require a new snapshot. This
foundation remains dark in product capabilities until the bound Inline reply
thread durably owns projection acknowledgement and ambiguous input recovery.
Server requests for approvals, questions, and tool calls on an attached thread
are claimed but left unanswered so this observation-only client cannot race an
existing controller; unclaimed requests still belong to the ordinary private
turn driver. Shared mutations therefore remain disabled. After detach or a
failed resume, the connection keeps a claim-only tombstone until it closes;
this prevents queued notifications or a late resume outcome from escaping into
the ordinary driver before an ordered dispatcher barrier exists. Codex also
enforces one rollout writer across app-server processes. The shared
host can fan multiple clients for a thread it owns, but cannot take over a
session currently held by a separate private app-server. The adapter preserves
that rejection. The shipping beta therefore uses the ordinary private turn
driver as an exclusive writer: selection only hydrates a bounded snapshot, the
first Inline input tries the exact `thread/resume`, active-writer rejection
becomes **active elsewhere** and unsubscribes only that rejected thread, and
provider-wide-idle `/close` ends Inline's epoch so another Codex surface can resume.
The shared observer remains dark rather than polling rollout files or implying
simultaneous multi-controller support.
