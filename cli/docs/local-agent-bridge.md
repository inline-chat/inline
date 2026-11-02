# Local coding-agent bridge

Inline's local bridge turns an installed coding agent into a bot. The bridge is
bundled with the Inline CLI and runs as one per-user background service. Agent
processes and project files stay on your computer.

Bridge v2 is the default for Codex, Claude, OpenCode v2 and the current pinned
Amp adapter. Each thread has one native session per agent. See
[Legacy bridge](#legacy-bridge) for what still runs on v1.

Maturity, as the Mac setup wizard labels it: Codex is alpha, Claude and OpenCode
are beta, Amp is experimental.

## Updates and restarts

The bridge applies a staged update once active work and pending publication
finish and two minutes have passed since the last work. A request that has
waited 24 hours skips the two minutes. Open idle sessions do not block it.
Admission closes atomically before the old runtime stops, so new work cannot
race the handoff.

`inline bridge status` and `inline bridge doctor` show the running CLI version,
the retained supervisor's version, and pending updates or rollbacks. The binary
in the bridge's `bin` directory belongs to the supervisor; its `--version` can
differ from the runtime doing agent work.

A deliberate `inline bridge stop` or `restart` during a candidate's startup
probation leaves that candidate available for retry. Crashes and failed health
checks still trigger rollback. A restart preserves thread settings and delivery
records, and sessions reopen when you next message them. Input that was written
to the agent but not confirmed is settled from the session when it reopens and is
never sent again. Input that never reached the agent gets a reply asking you to
send it again.

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

Without `--folder`, setup uses your home directory, and threads without a chosen
folder run there. Pass `--folder` to use a narrower project directory.

### Providers

- **Codex (alpha):** uses the native app-server protocol. It needs Codex 0.146.0
  or newer, including the runtime in the signed ChatGPT app. Newer features turn
  on per operation when the installed Codex's protocol schema has them.
- **Claude (beta):** runs the authenticated host `claude` directly and needs
  neither Node.js nor an adapter. Sessions resume natively.
- **OpenCode (beta):** runs `opencode acp` from OpenCode v2. OpenCode's application
  version is 2; its ACP wire protocol is v1. New setups require v2. To migrate,
  follow the [OpenCode guide](https://opencode.ai/v2/docs/migrate-v1/), check that
  `opencode --version` reports 2.x, then rerun `inline setup opencode`. Inline does
  not upgrade OpenCode or rewrite its configuration.
- **Amp (experimental):** runs Inline's source-pinned ACP adapter against the exact
  Amp executable accepted during setup. Run `inline setup amp` to install the
  current pin.

OpenCode and Amp run one private ACP process per session, so chats in the same
folder cannot share Inline tool bindings.

The Amp adapter is installed into immutable, private, versioned bridge
directories from Inline's embedded lock with `npm ci`. Package scripts and
optional native packages are disabled. Setup verifies the manifest, lock, adapter
version, integrity and executable path. The background service never downloads
or updates adapters.

## Using the bot

### Who it answers

Only structured addressing counts, never words in a message:

- A DM with the bot, or the bot's own thread: every message from someone with
  access.
- A group thread: a mention, a reply to the bot, or `/command@bot`. If a message
  starts with mentions of others and not this bot, it is for them.
- A group thread it follows: every message from a person with access. `/follow` and
  `/unfollow` change this. Inline may also set it when the bot opens a thread.

When the bot joins a group thread it gets up to 40 recent messages as untrusted
context. Later messages it was not addressed by travel with its next input, also
as untrusted context.

On Codex, in a thread where the agent actively participates, a side call can
decide that an unaddressed message deserves a reply. These checks have a budget
of 1,000 per day with an **Allow more today** button. Other providers answer only
when addressed.

### Commands

| Command | What it does |
| --- | --- |
| `/help` | This agent's commands, its harness commands, and its sub-agents. |
| `/status` | State, model, reasoning, permissions, folder name and harness version. |
| `/new [task]` | A new reply thread with a fresh session, in the parent's folder. |
| `/stop` | Stops the current turn. The session stays held and queued messages stay queued. |
| `/pause` | Stops the turn and holds queued input. Nothing runs until `/resume` or a new message to the agent. |
| `/resume` | Unpauses. Held input runs again in order. |
| `/queue <message>` | Runs the message after the current turn. There is no Undo. |
| `/model`, `/reasoning`, `/permissions` | Bare, shows choice buttons. With a value, sets it. Applies to this thread from the next message. |
| `/plan`, `/plan off` | Plan mode. On Claude, leave it by answering the plan or with `/permissions`. |
| `/review [branch]` | Codex reviews your uncommitted changes or the diff against a branch. |
| `/undo` | Undoes the last turn's file changes. |
| `/compact` | Compacts the session's context. |
| `/clear` | Clears the session's context. |
| `/follow`, `/unfollow` | Every message in this thread, or only mentions and replies. |
| `/allowlist` | Who may use the agent. See [Operator allowlist](#operator-allowlist). |
| `/release` | Lets the session go. The next message reopens it. |
| `/terminal` | Releases the session and shows the command to continue in a terminal. |

`/compact`, `/clear`, `/plan`, `/review`, `/undo` and `/release` reopen an idle
session first, including after a restart. If the thread never had a session they
say so.

`/projects`, `/folder`, `/sessions`, `/open`, `/close`, `/history`, `/verbose` and
`/threads` do not exist on v2. Choose the folder and output mode in Agent Settings.
A thread is a session, and `/new` starts another one.

### Provider differences

| | Codex | Claude | OpenCode | Amp |
| --- | --- | --- | --- | --- |
| Message during a turn | Steers | Steers | Waits for next turn | Waits for next turn |
| `/queue` | Yes | Yes | No | No |
| `/compact` | Yes | Yes | Yes | No |
| `/clear` | No | Yes | No | No |
| `/plan` | Yes | Yes | Build/Plan | No |
| `/review` | Yes | No | No | No |
| `/undo` | No | Yes | No | No |
| `/terminal` | Yes | Yes | No | No |

Some Codex rows depend on the installed version's protocol. A command the agent
cannot do says so and points to `/help`.

### OpenCode and Amp

ACP has no way to reach a running turn, and OpenCode rejects a prompt during one.
A message sent mid-turn gets a "reads this when its current turn ends" reply, then
runs as the next turn. An open card stays open in this case, because a denial could
not deliver the message anyway.

What else they can do depends on what the agent advertises:

- **OpenCode:** resume, model and reasoning settings, permissions, `/plan` as
  Build/Plan (`/plan off` returns to Build), compaction, usage and context
  reporting, and child sessions as nested rows. Its driver can also list, fork and
  close sessions.
- **Amp:** resume through Inline's private session records, a model setting
  offering Amp's low, medium, high and ultra modes, and default or bypass
  permissions. It has no reasoning setting, plan mode, compaction, session listing,
  fork or child rows. Images reach it as file links, not inline bytes.

Commands the agent advertises, such as OpenCode's own or Amp's `/init`, go to it as
typed unless Inline handles that name itself. An idle session keeps its process for
up to 30 minutes, and `/release` closes it at once.

A session that cannot be recovered keeps its binding and asks you to retry or use
`/new`. Old Amp adapter sessions cannot resume across processes.

### Skills and harness commands

Commands the harness reports appear in Inline's command menu after Inline's own, up
to 100 in total. The thread's folder is checked for project commands.

- **Codex:** `/skill-name` is sent as `$skill-name`.
- **Claude:** commands and skills are sent as `/name`. Names with hyphens and colons
  work typed in full, like `/code-review` or `/plugin:skill`, or by their menu name,
  where other characters become underscores, like `/code_review` or `/plugin_skill`.

Inline's own commands win on Codex and Claude. A command nobody recognizes is
reported as unavailable and is never sent as a prompt.

### Sessions

The session is released when idle. Claude closes after 30 idle minutes. Codex is
unsubscribed, and the app-server unloads it after its own `thread_unload_delay_secs`.
The next message reopens it.

If another client holds the session, the bot says so and offers **Fork here**, which
continues in a new thread. Your message stays pending and runs once the session is
free, if you still want it.

A session keeps its folder. To work in another folder, start a new thread.

### Output

Output mode is set in Agent Settings, as a default for the agent and an override
for the thread. The default is Detailed.

- **Detailed:** one progress message with every item the harness reports as
  collapsible rows, sub-agent items nested, then a separate final answer. A progress
  message continues in a new one past 80% of Inline's message limits. A steer ends
  the current progress message.
- **Friendly:** no progress cards. Only the harness's short prose updates, then the
  final answer.

Approvals, questions and errors are cards in both modes. Progress edits are silent;
the final answer notifies. While a turn runs, the bot shows a working status where
typing shows.

Agent Settings also has the model, reasoning, permissions, compact, the thread's
folder, the account's usage windows and the context window, as far as the harness
reports them.

### Permissions

New Codex threads start on Codex's **Approve for me**, and a thread Codex opened
before keeps its permissions. New Claude sessions launch with `bypassPermissions`.
A choice in `/permissions` or Agent Settings wins for that thread. The choices come
from the harness.

### Approvals and questions

Approvals are button cards in the conversation where the turn runs. The owner and
anyone holding the Approve grant can resolve them.

A question whose fields are all single-choice, with at most 8 options each, is asked
one field at a time with buttons. Other questions are forms. You can also reply to the card, with one answer per line
when there are several fields. Choices accept their number or label, and
multi-select takes a comma-separated line. A reply that does not read as answers is
a normal message to the agent. Anyone with access can answer a question.

Secrets never go through chat. A form with a secret field does not accept a reply.

A message sent while a card is open directs the agent instead of waiting behind it.
It denies the approval or dismisses the question, then reaches the agent, as a new
turn if the denial stopped the running one. A message never grants an approval. This
needs steering, so on OpenCode and Amp the card stays open.

### Agent loops

An agent stops answering other agents after 1,000 agent messages in a row without a
person, counted across the whole subthread tree. Edits to a message do not count. The
bot posts a notice with **Allow more**, which adds 1,000 and needs the Configure
grant. A message from a person resets the count.

### Files, photos, video, and voice

The bridge downloads each attachment up to 100 MiB into the provider's private
cache before delivery. If a download fails, it replies naming the file. Attachment
names, captions and contents are always untrusted input. A voice message is delivered
as its audio attachment.

- **Codex:** images and audio arrive as native local inputs, other files as a local
  path.
- **Claude:** supported images and PDFs are sent inline, other files as a local path.
- **ACP:** a standard resource link, plus image or audio bytes when the agent
  advertises them.

`return_attachment` sends a local file back as native Inline media, only when a
person asked to receive it. The file must be a regular file of at most 100 MiB inside
the thread's folder or the attachment cache. The agent chooses `image`, `video` or
`file`. Returned videos need `ffprobe` and `ffmpeg`.

## Inline tools for agents

The bridge serves 21 tools to the agent, acting as its bot. Codex gets them as
dynamic tools, Claude in-process, and OpenCode and Amp through a private stdio MCP
server.

- **Read:** `get_current_context`, `get_chat`, `get_messages`, `get_history`,
  `read_link`, `search_messages`, `search_chats`, `list_my_threads`,
  `get_reactions`, `list_pins`.
- **Write:** `send_message`, `add_reaction`, `remove_reaction`, `pin_message`,
  `unpin_message`, `edit_own_message`, `create_chat`, `start_subthread`,
  `return_attachment`, `ask_teammate`, `follow_thread`.

`pin_message`, `unpin_message`, `edit_own_message`, `create_chat` and
`return_attachment` require `confirmed_intent`, which the agent sets only when a
person asked. `create_chat` creates a private thread with the owner.
`start_subthread` moves the work into a new subthread and leaves a status card in the
thread. `ask_teammate` mentions someone in the work's thread.

A call resolves through the session that made it, so a session that no longer acts
for a work gets no tools. The server authorizes every request as the bot, and a link
never broadens access. Arguments are checked against strict schemas, and results and
run time are bounded.

## Project folders

A thread's folder is a choice in Agent Settings until a session works there. The
choices are the agent's own folder, the folders the harness knows (Codex's projects)
and the folders registered with the bridge. Agent Settings on v2 has no folder picker,
so register a new one on the host:

```bash
inline bridge workspace add /path/to/project --provider codex
inline bridge workspace list --provider codex
```

When multiple providers are configured, pass `--provider` to choose the target. Absolute
paths never travel through settings payloads; the choice is an opaque ID.

## Operator allowlist

The owner always has access. Everyone else needs a grant, which Inline's server holds
and the bridge checks on every message and again after any wait. The check is by
stable user ID. A mention never grants anything. Messages from people without access
never start work and get no reply.

The owner manages access in chat:

```text
/allowlist
/allowlist @name
/allowlist remove @name
```

`/allowlist` gives Invoke and Steer, per provider bot. It takes effect at once. The
Approve and Configure grants cannot be given this way.

`inline bridge operators` edits `~/.inline/config.toml`:

```bash
inline bridge operators list
inline bridge operators add 12345
inline bridge operators remove 12345
inline bridge operators add 23456 --provider claude
inline bridge operators list --provider claude
```

On v2 this list is imported as Invoke and Steer grants only while the bot has no
grants at all. After that, `operators` changes do not affect v2 access, including
`remove`. Use `/allowlist remove @name`.

## Background lifecycle and diagnostics

The bridge starts after login and survives ordinary process/provider failures:

- macOS uses a per-user LaunchAgent.
- Linux uses a per-user systemd service.

Linux service support is experimental until the exact artifact passes a real
systemd-user login, reboot, diagnostics, update, and cleanup run.

Linux starts with the user's systemd manager after login. `status` and `doctor`
report whether linger is enabled when `loginctl` is available; setup never
enables linger or requires headless pre-login operation.

One account service supervises all configured providers. A provider restart
does not stop other providers.

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

Development builds enable trace logging automatically, and
`inline bridge logs --lines 500` returns it. Release service builds keep trace
disabled; the hidden foreground `bridge run --trace` switch exists for an explicitly
supervised diagnostic run.

On Unix, a bundled supervisor holds one private installation-local ownership
lock, records its own verified group, and starts the provider in a separate
group. Provider descendants cannot inherit that lock. If the account service
is force-killed, its replacement signals the still-locked supervisor, which
stops the provider group it owns; a free stale PID record is never trusted.

The distributed macOS CLI is signed as the stable code identity
`chat.inline.cli`. If an explicitly selected agent workspace or a provider
operation touches a network volume, macOS may ask once for that filesystem
permission. Ad-hoc local development rebuilds do not have a stable signing
identity and can prompt again after the binary changes.

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
provider session records so a later setup can repair the installation.

## Troubleshooting

Start with `inline bridge status`, then `inline bridge doctor`. A provider may
be locally running while doctor reports `needs_attention` when its own CLI login
has expired; sign in with that provider on the host and run setup again. Use
`inline bridge logs --lines 100` for the bounded, redacted host diagnostic, then
`inline bridge restart` if recovery does not converge. Re-running
`inline setup <provider>` is idempotent and repairs the service binary, provider
record, command catalog, and background definition.

If a folder is missing from Agent Settings, run
`inline bridge workspace add <path> --provider <provider>` on the named host.

## Local security boundary

- The owner always has access. Others need a grant on Inline's server, rechecked on
  every message and after any wait. If grants cannot be read, only the owner is
  admitted.
- Bot credentials and the authenticated control token are stored in private
  local files and are not passed to provider processes.
- Provider authentication stays in provider-owned stores.
- Provider executables are resolved, probed, and persisted as exact paths.
- Doctor probes Amp through the same persisted host CLI path used by the
  service; it does not silently substitute another `amp` found on its own PATH.
- The Amp adapter requires an Inline-owned complete dependency lock. Setup is the
  only code-download boundary.
- The service exposes no public network listener. The Mac folder registrar binds
  only `127.0.0.1` on an ephemeral port and requires a fresh service-epoch
  capability, exact host installation ID, and selected bot identity.
- Registered workspace paths are canonicalized; the filesystem root is rejected.
- A thread without a chosen folder runs in the agent's folder for anyone with
  access. If setup used your home directory, that means home, so use `--folder`
  before granting access to others.
- Shared chats are treated as potentially visible to others. Messages from people
  without access never start work, but when the bot takes part in a thread they can
  reach the agent as untrusted context.
- Approval cards appear in the conversation where the turn runs and show the command
  and its folder as an absolute path. Bear this in mind before running work in a
  shared thread.
- Progress rows show paths relative to the session's folder where possible.
- Another bot needs a grant like anyone else and is checked the same way. It can
  activate this bot with a mention, a reply to it or a targeted command. Being a
  provider bot of the same bridge earns no exemption on v2.

## Legacy bridge

Bridge v1 still runs in three cases: `INLINE_BRIDGE_V2=off` in the bridge process's
environment, OpenCode 0.x or v1, and Amp adapters older than the current pin. A list
such as `INLINE_BRIDGE_V2=codex` enables v2 only for those providers. See
[CLI releases](releases.md#bridge-runtime) for how to set this for the background
service.

v1 keeps its own commands (`/projects`, `/folder`, `/queue`, `/threads`, `/verbose`
and `/allowlist <user_id>`) and uses the config allowlist live. Its Claude path needs
the ACP adapter and Node.js 22 or newer, so rerun setup with `INLINE_BRIDGE_V2=off`.
