# Local coding-agent bridge

Inline's local bridge turns an installed coding agent into a private bot. The
owner can use it in the bot DM, direct mentions, replies to the bot, and followed
Inline threads. All requests, including bot-authored requests, pass a strict
stable-user-ID allowlist before routing, context lookup, workspace binding, or
provider work; it contains only the owner by default. Unauthorized messages are
ignored silently, including DMs and commands; they cause no denial reply or
provider work. An allowlisted bot can activate it only with an exact structured
mention of this bot. Bot DMs, replies, followed-thread traffic,
generic mention flags, and targeted commands without that mention stay inert.
Bot authorship is disclosed to the coding harness, whose delivery guidance
requires explicit handoff mentions and warns against reciprocal loops. The Rust
bridge is bundled with the Inline CLI and runs as one per-user background
service; agent processes and project files remain on the user's computer.

## Setup

Authenticate the provider's own CLI first, then run setup. If the Inline CLI is
not logged in, an interactive terminal enters the normal Inline login flow
inside setup; JSON and other non-interactive use must provide an existing token.

```bash
inline setup codex --folder /path/to/project
inline setup opencode --folder /path/to/project
inline setup claude --folder /path/to/project
inline setup amp --folder /path/to/project
```

Setup creates or repairs that provider's bot, registers Inline's agent command
catalog, persists private local state, installs the user service, starts it, and
waits for the selected provider to become ready. Repeating setup is idempotent.
Adding a second provider preserves the first provider's bot, credentials,
workspaces, and sessions.

Without `--folder`, setup uses the user's home directory. Pass `--folder` to
use a narrower project directory.

Current beta provider paths:

- **Codex beta:** Codex 0.146.0 and every newer capability-compatible runtime,
  including the signed ChatGPT.app bundle, use the native app-server protocol.
  Setup checks
  a configured executable, `PATH`, then the signed ChatGPT application, while
  leaving provider authentication to Codex/ChatGPT. `/sessions` and `/open`
  list sessions for the conversation's verified project, read a bounded recent
  snapshot (including the current paginated `thread/turns/list` form), and
  create or reuse one titled Inline reply thread for that provider session.
  Opening history does not claim the provider writer. `/resume` acquires the
  exact Codex session in Inline's private app-server epoch and synchronizes
  history before prompts are accepted. Each prompt carries a stable client
  message ID; the existing
  semantic turn stream, activity disclosures, approvals, questions, final-send
  recovery, and rich Markdown projection remain the sole live path. Reopening
  idempotently hydrates only provider turns that Inline has not already
  completed and projected. Imported assistant Markdown goes through the same
  server-owned rich-content parser as live answers; a partial assistant item in
  the active tail is held back until Codex reports a stable historical turn.

  Inline uses **sequential** continuity, not simultaneous multi-client control.
  Running sessions remain visible with an availability label, but only
  provider-reported idle or unloaded sessions can be adopted;
  activity is checked again before import. Do not use another Codex client on
  the same session while continuing it in Inline. Writer enforcement varies
  across Codex runtimes and is not guaranteed by the shared app-server protocol.
  If Codex explicitly rejects a resume as owned elsewhere, Inline reports that
  condition; close the session there and use `/resume` in its linked Inline
  thread. `/resume` validates the same session and project, refreshes bounded
  history, and acquires it without sending a model prompt. A rejected resume
  unsubscribes only that thread without interrupting other Inline turns. If
  that cleanup cannot be confirmed, Inline deliberately ends and restarts the
  whole provider epoch before accepting more work.
  In a linked Codex thread, owner `/stop` interrupts its active turn, cancels
  its earlier queued messages, then attempts to release Inline's private
  provider epoch. Release waits for that turn's cleanup and succeeds only when
  all other Inline Codex work is idle; otherwise the reply asks you to retry
  `/stop` after the other work finishes. Wait for the release confirmation
  before continuing in ChatGPT Desktop or Codex CLI. The durable binding and
  Codex history stay intact. `/close` remains the idle-release alias. Use
  `/resume` before sending again; a premature prompt receives a reminder and
  must be resent after the ready confirmation. No Desktop launch options or
  CLI wrappers are required.
  The internal shared-socket observer
  remains a dark foundation and is not part of this beta claim. Older runtimes,
  missing required methods, and incompatible response shapes fail closed; a new
  Codex version number alone does not.
- **OpenCode experimental:** uses native Agent Client Protocol v1 through
  `opencode acp`.
- **Claude experimental:** uses the curated
  `@agentclientprotocol/claude-agent-acp` adapter. The pinned adapter advertises
  durable resume, but its cross-process `session/resume` path does not currently
  pass Inline's live reliability gate. After a bridge/provider restart, Inline
  therefore starts a fresh Claude session and says so instead of failing the
  first user direction or retrying an ambiguous resume.
- **Amp experimental:** uses Inline's source-revision-pinned ACP adapter in
  direct CLI mode with the exact authenticated Amp executable accepted during
  setup. The adapter is installed from an Inline-owned complete lock and
  integrity-checked embedded artifact. It has authenticated real-turn,
  host-tool-handshake, and cancellation evidence, but is not part of the
  Codex-only external beta claim.

The explicit Claude and Amp setup commands install only their required adapters
into immutable, private, versioned bridge directories using Inline's complete
embedded `package-lock.json` files and `npm ci`. Inline disables package scripts
and verifies the exact manifest, complete dependency lock, adapter version,
integrity, and executable containment before launch. Amp additionally verifies
the embedded executable bytes and pins its exact host CLI path; it disables IDE
detection and update checks for the managed ACP process. Amp adapter installs
omit the SDK's optional native CLI packages, and verification repairs older
installs that still contain one, so the separately verified host CLI is the
only executable runtime. Providers without an Inline-owned complete lock are
withheld from setup. The background service never downloads or updates
adapters. Claude currently requires Node.js 22 or newer.

## Using the bot

### Codex projects and existing sessions

Release acceptance for restart, host sleep/network changes, and the complete
physical-phone flow must be completed against the candidate bridge artifact.
The behavior below describes the implementation contract, not certification
of every Codex version or mobile surface.

Choose the current project in Agent Settings or with `/projects` (`/folder`
remains an alias), then run `/sessions` or `/open` in the owner bot DM. The
picker contains only that verified project and keeps provider IDs and host paths
out of callback payloads and messages. It includes indexed CLI, editor, and
app-server sessions, in six-session pages. **Load Older Sessions** fetches the
next provider batch without changing existing Open targets; up to 1,000
sessions can be loaded per picker. Empty and duplicate catalog pages are
skipped within a bounded request budget. Unindexed sessions, archived sessions,
and internal subagents are not included. Completed headless `exec` sessions
are included and can be resumed after their original process exits. Running sessions
are shown but cannot be opened until they become idle; refresh `/sessions`
after they finish. Session picker operations that read from Codex ask you to
finish the active turn first; already-loaded local pages remain usable.
Opening a choice
pre-fills a reply-thread title from the Codex title or preview, hydrates a
bounded recent provider snapshot, and durably pins that Inline thread to the
same Codex session and project. Browsing is read-only; `/resume` prepares
sequential continuation over private stdio before accepting prompts. Do not run the same
session concurrently in another Codex client. Continuous external observation,
simultaneous two-writer sync, and Codex mobile Remote interoperability are not
part of this beta.

Imports are bounded to 100 visible messages and 512 KiB of sanitized text.
Inline projects user messages and final answers; historical tool activity and
intermediate responses remain in Codex, as the linked-session status explains.
Newer Codex runtimes hydrate summary turns through bounded item pages; older
runtimes use compatible fallbacks. Omitted or unsupported history is marked
incomplete instead of silently presented as a complete import.

The picker snapshot and Open intent are written to the bridge's private local
database before the card is published. Page and Open callbacks therefore keep
working after a bridge/provider restart, recheck owner, bot, chat, message,
project, and expiry, and use one leased Open operation so duplicate phone taps
cannot create competing connections. A long Open runs in a bounded control
lane rather than the event-delivery loop. It terminalizes the card only after
the reply-thread binding, server connection, bounded projection, and status
identity are durable. The terminal copy says the session is linked and asks the
user to use /resume to sync history and enable prompts; opening alone does not claim that Codex has
resumed. Interrupted work stays retryable while the card is live. A partial
Open that already created a target thread fails closed after expiry, so queued
text cannot start a different ordinary session in that thread. The durable
reply-thread anchor also identifies a remotely created child before its chat ID
has been checkpointed; messages in that crash window are rejected with recovery
guidance instead of being default-bound. Callback
transport or card-edit failures do not by themselves restart Codex or interrupt
an unrelated turn.

On capable macOS filesystems, newly selected projects are verified across
reboots using a persistent volume and object identity. A replaced folder fails
closed. Projects saved by an older bridge are upgraded only when their complete
legacy filesystem identity still matches; a legacy project whose device
identity drifted requires one explicit reselection in Agent Settings or
`/projects` rather than silently adopting a different folder.

A pinned session thread cannot use `/new`, `/clear`, or a project setting to
silently become a different session. Bridge tool-contract updates also preserve
the exact pinned Codex identity; newly created sessions receive the updated
contract. Open another session from the bot DM instead. The release phase of
`/stop` (or idle `/close`) releases only
when every other Inline Codex lane in the provider epoch is idle, including
turn preparation and session mutation; it does not interrupt running work or
delete history. Codex can briefly report that the session is still closing
after release; retry there in a moment. Historical Codex user input is visibly
authored by the integration owner. An Inline-origin user-message echo is linked
back to the original Inline row using Codex's returned `clientId`, preserving
its real sender and text without duplication. Live input is linked only after
Codex accepts it. Normal-turn linkage failures retry once at completion;
steering linkage failures rely on later resync. `/resume`, or reopening from
`/sessions`, can repair an input link when Codex retained its `clientId`,
the matching local inbound record remains, and the item is in the bounded
history window. This is not autonomous or unlimited recovery. A final assistant answer is also
linked through a durable local repair record. If a restart makes the final send
or link response uncertain, the bridge reuses the same message identity and
repeats the idempotent link rather than losing provenance or publishing another
answer. After a successful /resume in the current provider connection, plain messages and unqualified commands in an opened session thread
continue that exact session; a fresh bridge store resolves the server-canonical
thread before it creates a new one.

Linked Codex sessions require `/resume` after Open, release, or provider restart. The bridge marks a session ready only after both writer acquisition and history sync succeed. If a prompt is submitted before that, it stays in Inline and receives a resume reminder; it is not sent to Codex or automatically replayed. Resend it after the ready confirmation. This is a send-time check, not a native composer typing banner. Ordinary new/headless conversations are unchanged.

### Claude projects and bounded history

Claude uses the same Agent Settings folder control and `/projects` picker as
Codex, so users can safely choose among verified recent folders without
exposing host paths in message actions. Native Claude session continuation is
not enabled yet. `/history` is the intentionally separate, owner-only local
history importer: it opens a bounded six-row picker, imports the visible
You/Claude branch into a private Inline reply thread, omits tool and attachment
blocks, redacts sensitive-looking local details, and does not resume or mutate
the original Claude session. `/sessions` and `/open` remain reserved for future
native continuity and return an explicit unavailable message if typed.

Each provider has a distinct bot and session namespace. A thread is a session
for the selected project by default. After a brief ordering gate, the bot
acknowledges every accepted provider direction with one silent, initially open
`Working` disclosure. It collapses that same message with elapsed-time copy such
as `Worked for 2m 14s`, `Stopped after 12s`, or `Failed after 8s`, then sends the
actual result as a separate message with changed-file and check summaries plus
a local **Copy Path** action for every safely representable relative path. These
ordinary messages arrive in the active conversation without quoting the
triggering message; only message-specific queue, failure, steering, or question
states use an explicit reply. While provider work is active, the bot publishes
Inline's native `typing…` compose action.
Progress and terminal-status edits are silent. The separate final answer uses
ordinary Inline sending and your normal notification settings, so intermediate
updates do not notify. The bridge persists the final send identity and reuses it
after a retry or restart; the retained status plus final answer are an intentional
two-message beta design. A failed progress edit never creates another progress
message or prevents the final answer; after a crash the bridge resolves the
original progress send by its stable local transaction identity before recovery.
Normal mode keeps the Codex presentation hierarchy and usually exposes 90–95%
of a turn: exact commentary, reasoning summaries, action rows, searches, file
reads, commands, tool metadata, provider plan steps, compaction notices, and
other structured activity inside that disclosure. Assistant item identity and
phase preserve first-seen ordering, while the final answer remains outside
progress. Normal mode stays within one bounded progress message and explicitly
marks the unusual turn that does not fit.

`/verbose` exposes the complete textual provider record retained by the bridge,
including reasoning content, command output, tool progress, exact commands and
paths, arguments, results, and raw Codex item payloads. It fills the existing
Working message to Inline's text limit of 100,000 UTF-16 units before adding a
densely packed silent continuation, so a command or provider item never creates a new message
by itself and no textual field is omitted. Binary generated
images remain lossless attachments instead of being duplicated as base64 text.
Formatting applies only structural Markdown/HTML escaping needed to keep the
disclosures valid; this output is not a credential-redaction boundary. Recovery
restores the same durable ledger, and switching from normal to verbose during a
turn reveals the verbose data already retained. Missing tool completion remains
unconfirmed even when the turn succeeds. The explicit `/verbose on` and
`/verbose off` forms remain available for automation.

The progress disclosure includes a footer such as
`Working directory: ~/dev/inline` (with the path rendered as inline code),
instead of sending a separate working-directory message on session creation or
resume. An actual session replacement still has its own explanatory notice.
`/new`, `/clear`, and a successful project-folder change report the same
working directory immediately. Paths below the host user's home are shortened
to `~/…`; workspaces elsewhere use only their final folder name so shared chats
do not disclose an absolute host path.

Bridge output is parsed with Inline's supported Markdown. Shell commands use
inline or fenced code. Changed-file paths use inline-code labels; in the
owner's top-level private DM those labels are clickable local `file://` links.
Outside the owner's top-level bot DM, changed files remain relative-path-only:
the bridge never publishes an absolute host path or `file://` target to a
thread.

Owner-authorized Agent Settings are available per DM or thread and share the
same underlying state as slash commands for project, model, reasoning,
permissions, verbosity, new session, clear, compact, queue, and stop behavior.
Opening settings never forwards thread messages to the provider. Unsupported
provider capabilities return a truthful status or use the durable queue; the
bridge does not scrape an interactive terminal.

Bare `/model`, `/reasoning`, `/permissions`, and `/folder` commands reply with
a silent interactive choice card. A page contains at most six choices plus
**Back**, **More**, and **Cancel**; paging edits the same message and does not
change a setting. The callback contains only an opaque token. Its durable local
record binds the original actor, owner privilege where required, bot,
installation, provider, conversation, workspace, command message, card message,
catalog fingerprint, page, and ten-minute expiry. Every click rechecks the live
operator policy and current catalog before the same settings mutation used by
typed slash arguments. Stale catalogs refresh the card without selecting a
fallback; restart recovery clears open cards. Explicit values such as
`/model <value>` remain supported for accessibility, automation, and older
clients. These settings remain owner-only even when another user is allowed to
drive the agent.

Provider-native commands now declare their input as no input, freeform input,
or a typed single-choice catalog while retaining the legacy freeform hint for a
compatibility window. A provider-declared single-choice command uses the same
durable card renderer. A successful click creates one replay-safe durable
inbound direction, so duplicate callbacks cannot start the provider command
twice. Freeform commands retain their usage hint and never fabricate buttons.

`/threads` controls where the next top-level turn is delivered. Bare
`/threads` shows the effective value and silent **Auto**, **On**, **Off**, and,
when applicable, **Reset** buttons. Typed `/threads auto|on|off|reset` remains
available. **Auto** is a real per-chat override; **Reset** removes the override
and inherits the provider/global default. The built-in default is `auto`:

```toml
[agent_bridge]
reply_threads = "auto"

[agent_bridge.providers.codex]
reply_threads = "on"
```

Inline reply threads are real child chats identified by both `parent_chat_id`
and `parent_message_id`. A turn already inside one stays there, while `/threads`
inside that child reads and changes its direct parent's policy. A linked child
without `parent_message_id` is an independent subthread with its own override.
For a top-level turn, `on` creates or reuses the triggering message's anchored
child and `off` stays in the current chat. `auto` stays flat in DMs and fresh
chats, creates a child in a non-DM after its latest message ID passes 15, and
also honors an explicit request such as “reply in a thread”; an explicit request
to stay in the main chat wins. The bridge records the delivery child before
`Working...` or provider startup; progress, questions, tools, `/stop`, final
delivery, and restart recovery then use that child identity.

Approvals are Inline action buttons in the owner's DM, and only the owner can
resolve them. A thread receives only a generic waiting status; sensitive
approval details remain in the owner DM.
Mid-turn owner directions steer when the provider supports steering; `/queue`
always queues explicitly and provides Undo until work starts.

`/stop` stops the typing indicator immediately and invokes the driver's
idempotent cancellation barrier. A successful barrier is terminal even when a
provider races or omits its final event. If it has not completed within five
seconds, Inline shuts down that provider epoch and restarts it instead of
leaving the turn visibly or durably active. For Codex, cancellation also starts
thread-wide managed-terminal cleanup immediately, repeats it after interruption
settles to catch late registration, and verifies that Codex's terminal registry
  is empty. The capability-probed Codex app-server contract does not provide an
OS-process-reaped acknowledgement, so
independently daemonized processes remain a provider limitation rather than an
absolute cancellation guarantee.

When an agent asks one to three non-secret questions, reply directly to the
question message. Choices accept either their number or label; multi-question
forms take one answer per line. Secret-entry requests are declined locally so
credentials never pass through Inline.

### Files, photos, video, and voice

Downloadable Inline media is retained as part of the provider-neutral user
direction, including its kind, CDN URI, MIME type, file name, and byte size.
The same bounded descriptor survives the durable inbox and explicit queue, so
provider restarts do not silently turn an attachment into text-only work.
If Inline first delivers a stored message before its media URL is hydrated,
the later copy may fill an empty attachment set only while that direction is
still accepted; it cannot overwrite prior media or mutate started work.
Captions remain the user direction; media without a caption receives a neutral
instruction to review the attachment. Attachment names, captions, and contents
are always untrusted user input.

Before provider startup, the bridge downloads each HTTPS attachment once into
the provider's private content-addressed cache with no redirects, a bounded
timeout, integrity verification, and a 20 MiB limit. The agent receives the
original transport descriptor plus a host-local read-only `file://` reference.
That local URL is passive agent context, not a user-accessible link and never an
instruction to upload. Codex receives cached photos and audio through
app-server's native `localImage.path` and `localAudio.path` inputs; the passive
descriptor still carries the corresponding local file URL for ordinary file
operations. Documents and video remain explicit untrusted local resource
descriptors. ACP providers receive native v1 `ImageContent` or `AudioContent`
only when the negotiated prompt capabilities advertise that modality. The
bridge also supplies the same attachment as a standard local `ResourceLink`,
so an agent can still refer to or return the exact file when its selected model
cannot inspect the media payload. Documents and video use `ResourceLink`
directly. No media
bytes, CDN URLs, captions, transcripts, or absolute cache paths are written to
bridge logs.

When the user explicitly asks to receive a file, photo, or other media, the
agent may call `return_attachment` and must choose Inline's native `image`,
`video`, or `file` kind from the current request. Images are returned as photos
and videos as videos; an image becomes a document only when the user asks for a
file or the format is not displayable media. The bridge accepts only a regular file
inside the active workspace or its private inbound-attachment cache, rechecks
the 20 MiB bound, validates the selected native kind against the MIME type, and
uploads it idempotently to the current conversation. Provider retries are
deduplicated by the authenticated direction, selected media kind, and verified
file bytes rather than the provider's call ID. Native video uploads preserve
Inline's verified inbound width, height, and duration when returning an
attachment; workspace videos are probed with a bounded `ffprobe` invocation and
fail closed instead of silently becoming documents when metadata cannot be
verified. Every returned video also receives a bounded JPEG thumbnail generated
with `ffmpeg`, uploaded in the same multipart request, and attached to the
native Video. The response mapper selects the requested Video ID even though a
thumbnail upload also returns a Photo ID. Inbound media preserves its
user-facing file name. This makes the result available from any Inline device without
exposing a host-local or `/tmp` path. Merely mentioning, reading, editing,
changing, or referring to a path must not trigger this tool; the agent's normal
answer remains text unless the user explicitly asks to receive the artifact.

Provider-generated images use the same provider-neutral output boundary in the
other direction. Codex `imageGeneration` completions are accepted only when
the saved PNG exactly matches the bounded base64 result reported by app-server.
ACP native agent-message images are decoded only from bounded base64 when their
declared PNG, JPEG, WebP, or GIF MIME type matches the file signature, then
materialized into the provider's private state directory.
The durable final-send record stores only the absolute path, byte length, MIME
type, safe file name, and SHA-256 digest. Delivery rechecks the regular file,
size, digest, and matching raster signature before using Inline's idempotent photo upload,
then sends the agent's terminal text. Recovery repeats both sends with stable
identities, so a restart cannot duplicate or silently lose a staged image.

A new voice message with no caption waits up to ten seconds for Inline's
server-generated transcription edit. The wait is an independent timer and
does not block other messages, chats, provider output, or `/stop`. If the edit
arrives first, its transcript and voice resource become one initial direction.
If the timer wins, the original audio resource is durably queued. A later edit
to the exact source message of an active steer-capable turn is sent as a native
steer with a revision-scoped deduplication identity; edits to other or completed
messages do not become new agent directions. `/stop` cancels any voice messages
still held in that chat's transcription window, so delayed audio cannot start
after the stop acknowledgement.

## Inline tools for agents

The bridge owns one bot-authenticated Inline tool catalog and authorization
core; provider drivers only adapt that catalog to a verified transport. Every
call is rebound to the accepted initiating turn, exact bot installation,
provider session, live stable-user-ID policy, and a chat the bot can access.
Arguments use strict per-tool schemas, results and item counts are bounded,
calls time out, and durable provider/session/turn/call identities prevent a
replayed mutation from running twice. Ordinary assistant answers still return
through the bridge's durable final-message path rather than a send-message tool.

The initial catalog covers current context, chat/message/history lookup,
message and chat search, reactions, pins, top-level chat creation, returning an
explicitly requested local artifact as an Inline file, editing this bot's own
messages, updating this bot's name, and bot presence. Mutations with meaningful
side effects require explicit user intent; creating a public chat requires a
second explicit public-chat intent. There is no reply-thread creation tool,
arbitrary HTTP, raw RPC, CLI, general filesystem access, owner-token, or general
send-message capability.

Compatible Codex app-server versions receive these as native `inline.*` dynamic
tools. OpenCode, Claude, and Amp receive the same catalog through stable ACP
v1's required stdio MCP transport. For each provider session, ACP launches the
current Inline binary in a hidden MCP-only mode with an ephemeral capability and
loopback port. That
child receives no Inline credential, bot token, durable bridge state, or
workspace mapping. The parent maps the capability back to the provider session
and currently active turn, then invokes the same catalog and authorization core
used by Codex. Capabilities expire with the provider epoch, calls outside an
active turn fail closed, and the unstable MCP-over-ACP extension is not used.

## Project folders

Agent Settings shows up to eight quick choices and keeps **Pick a Folder…**
last. **Browse all projects…** opens the complete paged catalog. For Codex,
this combines official `project/list` results, saved desktop project roots
(including the older saved-folder format), and Inline's registered folders;
it does not infer projects from recent sessions. `/projects` uses the same
catalog, with up to 1,000 verified local roots. Multiple roots of one Codex
project appear as separate folders. Remote and Cloud roots are not included.
Discovery never changes the selected folder or replaces its saved filesystem
identity. The most recently explicitly selected folder remains the default for
new threads. An iPhone or another computer can switch among these projects but
cannot browse the bridge host's filesystem.

The remote iPhone controls are implemented but remain outside the initial
macOS Codex beta certification until they pass the physical-device acceptance
matrix.

On the bridge-host Mac, Inline owns the native folder chooser and registers the
selected path through a capability-authenticated loopback-only endpoint. The
bridge canonicalizes and validates the directory and returns an opaque workspace
ID. Absolute paths never travel through bot-settings payloads. The only message
exception is an owner-DM changed-file `file://` link generated after the bridge
has proved workspace containment.

The registrar accepts both the original Mac client's `ID` JSON field spelling
and the canonical `Id` spelling. A CLI update fixes folder picking for those
existing Mac clients; no Mac update or server deployment is required. Saved
catalog failures show an explicit warning while keeping local folder recovery
available. Reopen Agent Settings after a bridge restart to refresh its capability.

The CLI provides the same registry escape hatch:

```bash
inline bridge workspace add /path/to/project --provider codex
inline bridge workspace list --provider codex
```

When multiple providers are configured, pass `--provider` to choose the target.

## Operator allowlist

The owner is always allowed and cannot be removed. Other users are rejected
before routing, context, session, provider, or tool work unless their exact
stable Inline user ID is allowed. Shared-chat rejection is silent; a direct
message receives at most one generic silent rejection per bounded window. The
global allowlist applies to every configured provider; `--provider` creates an
exact provider override of that global list.

```bash
inline bridge operators list
inline bridge operators add 12345
inline bridge operators remove 12345
inline bridge operators add 23456 --provider claude
inline bridge operators list --provider claude
```

These commands update `~/.inline/config.toml`, validate unique positive IDs,
and restart the account bridge. The equivalent configuration is:

```toml
[agent_bridge]
allowed_user_ids = [12345]

[agent_bridge.providers.claude]
allowed_user_ids = [23456]
```

This file belongs to the current authenticated Inline user. That owner is
implicit in the policy and need not also appear in `allowed_user_ids`.
The owner can also send `/allowlist <user_id>` to one provider bot. Inline
resolves and shows that user's full name and username in a confirmation card;
only the owner's **Allow** button updates that provider's override, while
**Cancel** leaves it unchanged. The live policy updates without restarting the
service. Setup migrates the temporary legacy `~/.inline/config.json` policy to
TOML when needed and retains the JSON file as a non-destructive,
non-authoritative backup.

## Background lifecycle and diagnostics

The bridge starts after login and survives ordinary process/provider failures:

- macOS uses a per-user LaunchAgent.
- Linux uses a per-user systemd service.

Linux service support is experimental for the beta until the exact artifact
passes a real systemd-user login, reboot, diagnostics, update, and cleanup run.

Linux starts with the user's systemd manager after login. `status` and `doctor`
report whether linger is enabled when `loginctl` is available; setup never
enables linger or requires headless pre-login operation.

One account service supervises all configured providers. A provider restart
does not stop its siblings, and at most four independent agent turns run across
the whole account at once.

Before upgrading an existing on-disk bridge database, Inline creates a
permission-restricted sibling backup as the rollback point. If an older backup
for the same schema transition already exists, a new generation is preserved
instead of reusing stale state. Stop every bridge process before restoring a
backup and starting an older binary. Local bindings and other bridge state
created after that backup are not present in the rollback copy.

```bash
inline bridge status
inline bridge doctor
inline bridge logs --lines 100
inline bridge stop
inline bridge start
inline bridge restart
```

`status` and `doctor` report each configured provider separately. Logs are
bounded and redact provider/protocol failures before display.

Development builds enable a metadata-only trace stream automatically. It
correlates stable Inline event/message IDs, provider session/turn IDs, RPC
methods, normalized event kinds, tool-call IDs, durable claim outcomes, stop
barriers, voice-wait phases, source-edit steering, attachment counts, and
elapsed times. It never records message text, media URLs, transcripts, tool arguments or
results, file contents, absolute workspace paths, tokens, or credentials.
`inline bridge logs --lines 500` returns the bounded trace when diagnosing a
beta failure. Release service builds keep trace disabled; the hidden foreground
`bridge run --trace` switch exists for an explicitly supervised diagnostic run.

On Unix, a bundled supervisor holds one private installation-local ownership
lock, records its own verified group, and starts the provider in a separate
group. Provider descendants cannot inherit that lock. If the account service
is force-killed, its replacement signals the still-locked supervisor, which
stops the provider group it owns; a free stale PID record is never trusted.

The distributed macOS CLI is signed as the stable code identity
`chat.inline.cli`. If an explicitly selected agent workspace or a provider
operation touches a network volume, macOS may ask once for that filesystem
permission. Ad-hoc local development rebuilds do not have a stable signing
identity and can prompt again after the binary changes; they are not suitable
as the exact beta artifact.

Production bridge state lives below
`~/.local/share/inline/bridge/accounts/<owner-user-id>/`. Each account has one
private manifest, protected credential envelope, installed service binary,
control socket, bounded logs on macOS, and isolated provider state directories.
Development builds use the sibling `inline-dev` data root. The login service is
`~/Library/LaunchAgents/chat.inline.agent-bridge.<owner-user-id>.plist` on macOS
or `~/.config/systemd/user/chat.inline.agent-bridge.<owner-user-id>.service` on
Linux.

To remove only the background service while preserving bots, credentials,
configuration, workspaces, and session state:

```bash
inline bridge uninstall
```

Uninstall removes only the launchd/systemd definition and stops the background
process. It preserves bots, credentials, registered projects, settings, and
provider session records so a later setup can repair the installation. Whether
the provider can resume a recorded session is capability- and
reliability-gated; the current Claude adapter deliberately starts a fresh
session after a process epoch changes.

## Troubleshooting

Start with `inline bridge status`, then `inline bridge doctor`. A provider may
be locally running while doctor reports `needs_attention` when its own CLI login
has expired; sign in with that provider on the host and run setup again. If a
provider is restarting, accepted directions remain queued and healthy sibling
bots stay available. Use `inline bridge logs --lines 100` for the bounded,
redacted host diagnostic, then `inline bridge restart` if recovery does not
converge. Re-running `inline setup <provider>` is idempotent and repairs the
service binary, provider record, command catalog, and background definition.

If **Pick a Folder…** is unavailable, use an existing recent project or run
`inline bridge workspace add <path> --provider <provider>` on the named host.
The Mac picker is intentionally unavailable from iPhone, a remote Mac, or when
the local service-epoch probe fails.

## Local security boundary

- The owner user ID is the default operator and the only approver. Additional
  operators require an exact stable ID granted through local CLI/config or the
  owner's `/allowlist <user_id>` confirmation card.
- Bot credentials and the authenticated control token are stored in private
  local files and are not passed to provider processes.
- Provider authentication stays in provider-owned stores.
- Provider executables are resolved, probed, and persisted as exact paths.
- Doctor probes Amp through the same persisted host CLI path used by the
  service; it does not silently substitute another `amp` found on its own PATH.
- Curated ACP adapters require an Inline-owned complete dependency lock. Setup
  is the only code-download boundary, installs with `npm ci`, verifies that lock
  and the adapter integrity, and reports a new install explicitly.
- The service exposes no public network listener. The Mac folder registrar binds
  only `127.0.0.1` on an ephemeral port and requires a fresh service-epoch
  capability, exact host installation ID, and selected bot identity.
- Workspace paths are canonicalized; filesystem root and the home directory are
  rejected as projects.
- Shared/public chats are treated as potentially internet-visible. Admission is
  based only on the strict stable-user-ID allowlist, never group membership.
  Non-allowlisted human messages are excluded from provider context; approval
  details, absolute local paths, and `file://` targets remain owner-DM-only.
- Another bot must pass the same live user-ID allowlist and exactly mention this
  bot. A targeted command or reply alone does not authorize or activate it.
  Other bot messages are ignored silently. Ordinary responses to bots are sent
  without a structural reply or reciprocal mention; bridge-authored guidance
  permits a bot mention only for a necessary explicit handoff. Message metadata
  is checked first and missing bot classification falls back to Inline's stored
  user identity.
- `/allowlist` is the only in-chat allowlist mutation. It is provider-scoped,
  owner-only, confirmation-gated, and rechecks the callback's user, bot, chat,
  expiry, and durable one-shot token before changing the live policy.
