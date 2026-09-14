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
the ordinary driver before an ordered dispatcher barrier exists. Writer
ownership is not a universal app-server guarantee: multiple shared clients can
subscribe, and starting input during another client's turn can steer that turn.
The beta therefore uses private stdio for sequential continuation: selection
only hydrates a bounded snapshot, and explicit `/resume` tries the exact
`thread/resume` and synchronizes history before prompts are accepted.
Provider-confirmed active-writer rejection becomes **active
elsewhere** and unsubscribes only that rejected thread. Provider-wide-idle
`/stop` (or idle `/close`) ends Inline's epoch so another Codex surface can resume. Do not run the
same session concurrently in another Codex client.
The shared observer remains dark rather than polling rollout files or implying
simultaneous multi-controller support.

Compatibility uses a minimum protocol floor (0.146.0), not an exact-version
allowlist or an upper bound. Launch probes only bounded read-only list/read
shapes. History negotiates summary turn pages plus item pages, falls back to
full turn pages on older implementations, and uses legacy full reads only when
paging is unavailable. Additive fields/enums are tolerated; unknown session
states are unavailable for adoption, and incompatible operations fail closed.
Future breaking protocols still require adapter updates, not version pinning.
