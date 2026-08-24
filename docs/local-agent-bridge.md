# Local coding-agent bridge

Inline's local bridge turns an installed coding agent into a private bot. The
owner can use it in the bot DM, direct mentions, replies to the bot, and followed
Inline threads. Human-authored requests pass a strict stable-user-ID allowlist
before routing, context lookup, workspace binding, or provider work; it contains
only the owner by default. Another bot can activate it only with an exact
structured mention of this bot. Bot DMs, replies, followed-thread traffic,
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

- **Codex beta:** exactly Codex 0.146.0 uses native `codex app-server`. This is
  the only provider/version target with compatibility evidence; newer versions
  fail closed until their protocol compatibility is separately certified.
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

Each provider has a distinct bot and session namespace. A thread is a session
for the selected project by default. After a 100 ms ordering gate, the bot
acknowledges every accepted provider direction with one silent `Working...`
message. It terminalizes that message with elapsed-time copy such as
`Worked for 2m 14s`, `Stopped after 12s`, or `Failed after 8s`, then sends the
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
Normal mode remains exactly `Working...` while a turn runs and never invents task
counts or plan summaries. `/verbose` toggles a per-conversation, live view of
safe structured provider activity. That view keeps first-seen work, normalized
command labels, plan steps, and validated relative file paths in emission order;
updates change the existing row without clearing earlier work. Bounded silent
continuation messages preserve prior rows on overflow, and recovery restores the
same durable ledger. Raw reasoning, terminal output, tool payloads, environment
values, secrets, and absolute paths are never progress content. The explicit
`/verbose on` and `/verbose off` forms remain available for automation.

When a provider session is first created, resumed after a bridge process
restart, or automatically replaced, the bot also sends one silent status such
as `Working directory: ~/dev/inline` (with the path rendered as inline code).
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
is empty. Codex 0.146 does not provide an OS-process-reaped acknowledgement, so
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

Codex 0.146 receives these as native `inline.*` dynamic tools. OpenCode and
Claude receive the same catalog through stable ACP v1's required stdio MCP
transport. For each provider session, ACP launches the current Inline binary in
a hidden MCP-only mode with an ephemeral capability and loopback port. That
child receives no Inline credential, bot token, durable bridge state, or
workspace mapping. The parent maps the capability back to the provider session
and currently active turn, then invokes the same catalog and authorization core
used by Codex. Capabilities expire with the provider epoch, calls outside an
active turn fail closed, and the unstable MCP-over-ACP extension is not used.

## Project folders

Agent Settings shows up to eight recent projects and keeps **Pick a Folder…**
last. The most recently selected folder becomes the default for new threads.
An iPhone or another computer can switch among already registered projects but
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
  bot, target its command entity, or reply to this bot's own stored message.
  Other bot messages are ignored silently. Ordinary responses to bots are sent
  without a structural reply or reciprocal mention; bridge-authored guidance
  permits a bot mention only for a necessary explicit handoff. Message metadata
  is checked first and missing bot classification falls back to Inline's stored
  user identity.
- `/allowlist` is the only in-chat allowlist mutation. It is provider-scoped,
  owner-only, confirmation-gated, and rechecks the callback's user, bot, chat,
  expiry, and durable one-shot token before changing the live policy.
