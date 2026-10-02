# @inline-chat/hermes-agent-adapter

Inline platform plugin for Hermes Agent.

This package installs an external Hermes platform plugin named `inline` and a
supervised Node sidecar that uses `@inline-chat/realtime-sdk` for Inline
realtime transport.

Implemented Hermes-native surfaces:

- realtime inbound messages, replies, and action callbacks
- outbound text, markdown, opt-in edit-message streaming, deletes, typing, media uploads, and reply threads
- Native Hermes `inline` tool for bounded chat/message/history/search/thread, reaction, pin, and agent-authored button-message actions
- clarify prompts, command approvals, slash confirmations, and model picker buttons
- Hermes slash commands synced into Inline's native `/` bot command menu
- DM/group access policy controls compatible with Hermes gateway allowlists
- installer, doctor, dry-run, and live `test-send` probes

## Feature Support

Supported:

- Install, status, doctor, dry-run, and live `test-send` commands.
- External Hermes platform registration as `inline`.
- `INLINE_TOKEN`, `INLINE_BOT_TOKEN`, `platforms.inline.token`, and `inline.token` auth paths, including simple `${ENV_NAME}` config references.
- Supervised loopback Node sidecar using the Inline realtime SDK.
- Realtime inbound messages, catch-up, replies to bot messages, and action callbacks.
- Inbound SDK receipts remain pending until the matching host durably adopts a model input, completes a synchronous control, or proves a permanent refusal. Temporary routing-metadata and authorization failures retry before deduplication or effects, preserving per-chat order while other chats can progress. Lost acknowledgement responses retry only the acknowledgement. Other agent-button dependency failures have bounded retries and a retry prompt; unavailable sender-kind proof always remains pending. Shutdown leaves unresolved receipts available for catch-up. Durable intake does not promise exactly-once model turns or external effects.
- Outbound text, Markdown parsing, opt-in edit-message streaming, long-message splitting, edits, deletes, typing, and presence.
- Inline reply-thread routing, explicit-request auto mode, `/threads` controls, explicit `/follow` and `/unfollow` dialog relevance controls, parent chat metadata, parent/thread prompt fallback, and thread-specific skill bindings.
- Native Hermes `inline` tool for current-chat/thread reads, bounded history and search, exact message lookup, button-message sends, editing/deleting bot-owned messages, reactions, pin/unpin/list pins, reply-thread creation, top-level chat creation, participant changes, chat renaming/deletion, explicit emoji backfill, and avatar presence/status.
- Explicitly mentioned Agents and this bot's bound `agentContext` select specialized instructions for accepted turns. Lookup or identity failure leaves delivery pending instead of running the generic bot. Binding does not bypass mention requirements or access policy. Instructions enter the current turn's context without rewriting an existing Hermes system prompt.
- Cached, privacy-safe sender names/usernames plus chat/thread IDs, selective reply/thread/observed context, and parent-thread context, with first-name/username Markdown mention guidance and current chat/thread links.
- OpenClaw-style entity summaries for live turns and tool-fetched history, including mentions, text links, thread links, thread-title links, code/pre blocks, bot commands, and group mentions as untrusted Hermes context.
- DM and group policies, user allowlists, group sender allowlists, mention requirements, strict mention mode, allowed chats, and free-response chats.
- Native Inline `/` command-menu sync for Hermes slash commands, including `/threads`, `/follow`, `/unfollow`, `/inline_sync`, `/inline_version`, and `/update`; typed slash commands continue to work even if menu sync is disabled or rejected.
- Inline-native buttons for clarify prompts, command approvals, slash confirmations, and model selection.
- Agent-created `send_message`/`edit_message` button rows with opaque callback data. Model-directed callbacks enter Hermes as normal turns naming the source message and exact action fields; durable host adoption precedes acknowledgement. The normal response edits that source message and clears omitted buttons; the agent can instead call `edit_message` with replacement buttons and finish with `NO_REPLY` so the explicit edit remains authoritative.
- Outbound local photo, video, voice, and document uploads with configurable size caps.
- Inbound photo, video, voice, and document summaries, with URL-backed media cached locally for Hermes when available.
- Reactions on bot messages, plus opt-in lifecycle/system events as synthetic Hermes messages.
- Cron or standalone sends through `INLINE_HOME_CHANNEL` and `hermes send --to inline:<chat-id>`.
- Hermes-native `typing_indicator` and `gateway_restart_notification` toggles, with plugin-owned YAML bridge coverage for external-plugin compatibility.

Unsupported or intentionally limited:

- Multiple Inline accounts assigned to one adapter or one Hermes profile. Each receiving adapter owns one authenticated bot. The candidate supports distinct configured named profiles with separate credentials, listeners, state and settings; concurrent multi-profile receiving still requires the matching core and its runtime acceptance checks.
- Space management and administrative tools beyond the supported chat operations.
- Full Inline rich-text span conversion. Outbound formatting uses [Inline's bounded Markdown surface](../../packages/protocol/docs/markdown.md); rich entities are summarized for the agent instead of converted into Hermes-specific spans. Parsing is enabled by default, while disabling it preserves the supplied syntax literally.
- Native animated draft streaming. Inline can stream by sending one preview message and editing it, but this edit-based streaming path is off by default like Discord and Slack.
- Ephemeral in-channel private replies. Private notices are sent as DMs when a user id is available.
- Live voice sessions or calls. Voice file messages are supported, but realtime audio is not.
- Media without a usable Inline CDN/local URL. Those messages still produce text summaries, but Hermes may not receive a local file path.

## Install

```sh
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
hermes gateway setup
```

When installation runs as root but the Hermes home belongs to its service user,
the installer automatically aligns the plugin directory ownership with that
service user. Use the same service user and Hermes home when applying manual
npm updates.

Select Inline in the messaging-platform picker. The default path is: go to
**Inline → Settings → Bots → Create a new bot**, then paste its token. See the
[Inline bot creation guide](https://inline.chat/docs/creating-a-bot). The
optional CLI path can install/sign in to the Inline CLI and create the bot from
the terminal. Both paths securely save the token and configure access.

## Coding Agent Setup Prompt

For an existing server or Umbrel installation, follow the
[remote Hermes setup guide](https://inline.chat/docs/hermes.md). Run setup in
the existing container as its service user with the same persisted Hermes home
and profile. The guide includes a copyable coding-agent prompt, persistent
installation paths, browser approval over SSH, and live verification.

After signing in with `inline login --browser --no-open`, the CLI can configure
the channel without putting tokens in command arguments:

```bash
inline agents setup --target hermes --dry-run --non-interactive --json
inline agents setup --target hermes --non-interactive --json
```

Add `--profile NAME` for an existing named profile. Preserve the existing
models, memory, skills, and channels. Do not read or print `.env` files or
secrets. A dry-run or credential probe is not proof of a live reply; verify
the running gateway and a final response in Inline.

For local development:

```sh
cd plugins/hermes-agent
bun run build
node dist/install.js install --link --hermes-home ~/.hermes
cd ~/dev/hermes-agent
uv run ./hermes plugins enable inline-platform
```

Check an installation:

```sh
inline-hermes doctor --json
hermes inline status --json --probe
hermes gateway status
inline-hermes --version
```

Hermes publishes its installed skill catalog to Inline on gateway connect.
Running Hermes' `/reload-skills` now republishes both the native command menu
and skill catalog through the adapter's live refresh hook. From an authorized
Inline chat, `/inline_sync` is the direct recovery command for the same full
republish. After it succeeds, open or reopen Inline's Skilled Agent editor to
load it. `/inline_version` reports the loaded plugin and Hermes versions, the
installed/updated filesystem timestamp when available, and the last
in-process catalog-sync result without exposing paths, tokens, or config.

The Inline CLI can drive Hermes setup without putting the bot token in argv:

```sh
inline agents setup --target hermes --non-interactive --json
```

For other orchestrators, the plugin also exposes a token-free machine contract.
The token is accepted only on stdin and is saved through Hermes's credential
helper:

```sh
printf '%s\n' "$INLINE_BOT_TOKEN" | hermes inline setup \
  --non-interactive --token-stdin --owner-user-id 123 \
  --access owner --json
hermes inline status --json --probe
```

`doctor` verifies required plugin files, the Node executable used for the
sidecar, the installed sidecar bundle hash, and whether Hermes config enables
the external plugin with `plugins.enabled: [inline-platform]`. It detects
Inline credentials from the current environment, Hermes config, or the managed
credential store used by `hermes gateway setup`, without printing token values.
It honors `INLINE_NODE_BIN` and fails if that explicit path is missing, not
executable, older than Node 20, or cannot report a Node version. It also fails
if a copied plugin has drifted from the package bundle.

Confirm Hermes sees the plugin:

```sh
cd ~/dev/hermes-agent
uv run ./hermes plugins list --plain --no-bundled
```

Expected local output includes:

```text
enabled      user     0.0.22   inline-platform
```

## Update Or Reinstall

After upgrading the npm package, refresh the installed Hermes plugin copy:

```sh
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
inline-hermes --version
inline-hermes doctor --json
```

`install --force` replaces the copied plugin files under
`~/.hermes/plugins/inline` or refreshes a dev symlink target. It does not edit
`config.yaml`, tokens, or other Hermes state. If `doctor` reports a sidecar hash
mismatch, rerun the same command after rebuilding or upgrading the package.

## Compatibility

- Hermes Agent: the external user plugin registry and native platform loader in
  Hermes Agent `>=0.21.3` establish the historical loader/send-only floor.
  Receiving requires the reviewed fork pinned by the manifest, currently
  `morajabi/hermes-agent@cd7f349d7aa072f45fce5d2721869ba59c5bbfa2`.
  Its source-derived base version is `0.21.5`; that version alone does not prove
  the required core capabilities. Packaged receiving qualification is pending.
- CI checks the minimum supported Hermes release, newest stable source, and upstream
  `main`. A six-hour scheduled check also tests the published npm `latest` adapter.
  `inline-hermes doctor` requires successful host loading, credential validation
  and the actual durable receiving core capability. Unavailable Hermes diagnostics
  no longer count as healthy. A connected gateway remains a separate runtime check.
- Node.js: `>=20` is required for the bundled sidecar. Hermes-managed Node 22,
  system Node, or an explicit `INLINE_NODE_BIN` path all work.
- Inbound recovery retries without waiting for another message or reconnect. Independent chats are consumed concurrently; same-chat order and delivery acknowledgements are preserved. Sender provenance lookups start with a short timeout and expand up to the existing SDK ceiling after timeouts; deferred inputs stay recoverable. A successful directory fetch that misses the requested sender can refresh after the one-second retry interval; verified users retain their normal cache TTL. Stream replacement wakes pending backpressure writes.
- Inline transport: this local candidate pins `@inline-chat/realtime-sdk@0.0.19-alpha.0`
  and the matching protocol candidate. Their immutable local tarballs qualify this
  build without asserting registry publication. The sidecar is bundled, so Hermes
  startup does not run `npm install`.
- Live sends require a valid Inline user or bot token in `INLINE_TOKEN`,
  `INLINE_BOT_TOKEN`, `platforms.inline.token`, or `inline.token`.

Use `hermes plugins list --plain --no-bundled` to verify external plugin
registration. Other Hermes channel listings may be limited to bundled platforms
depending on the Hermes version, but `hermes send --to inline:<chat-id> ...`
and the gateway path load the external plugin through Hermes' platform registry
after `hermes plugins enable inline-platform`.

## Maintainer Preflight

Before publishing, run:

```sh
bun run release:preflight
```

This creates an isolated registry-dependency stage, runs the full package
check, packs one read-only tarball, and runs `npm publish --dry-run` against
those exact bytes. It prints the artifact path, SHA-256, and file list so the
trusted-publishing workflow can hash-check and publish the same artifact.

Maintainers should also run the manual live-test and publish checklist in
[`plugins/hermes-agent/RELEASE.md`](https://github.com/inline-chat/inline/blob/main/plugins/hermes-agent/RELEASE.md).

## Smoke Test

Dry-run mode validates target parsing and package wiring without a token:

```sh
inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json
```

With a valid Inline bot or user token in the environment or Hermes config,
`test-send` starts the bundled sidecar on a loopback port, waits for realtime
readiness, sends one message, and shuts the sidecar down:

```sh
export INLINE_TOKEN="<token>"
inline-hermes test-send --to chat:123 --text "Inline Hermes test"
```

Use `--json` for automation. Tokens are read from `INLINE_TOKEN`,
`INLINE_BOT_TOKEN`, `platforms.inline.token`, or `inline.token`; the CLI
intentionally does not accept token arguments. If the token is expired or
revoked, the JSON `issues` array includes the server connection reason, for
example `SESSION_REVOKED`.

## Configure

Set an Inline token in the Hermes gateway environment:

```sh
export INLINE_TOKEN="<token>"
```

Then enable the platform in Hermes config:

```yaml
platforms:
  inline:
    enabled: true
```

Inline follows Hermes' native work-chat defaults: show typing/presence while a
turn is running, keep tool-call progress out of the room by default, and keep
edit-based token streaming opt-in. If an older Hermes config has global
`display.tool_progress: all`, add the per-platform override below so terminal
and tool progress bubbles are not left in Inline chats:

```yaml
display:
  platforms:
    inline:
      tool_progress: off
      cleanup_progress: true
      streaming: false
      interim_assistant_messages: false
```

To temporarily show live tool progress, set `tool_progress: new` or
`tool_progress: all` and leave `cleanup_progress: true` so Hermes deletes the
progress message after a successful final reply. Token streaming requires both
top-level `streaming.enabled: true` and
`display.platforms.inline.streaming: true`.

Hermes-native sends and scheduled deliveries accept Inline's explicit target
forms: a bare positive ID or `chat:ID` for a chat, `thread:ID` for a routable
reply thread, and `user:ID` for a direct user target. IDs are validated as
positive signed 64-bit integers before delivery. The parser hooks activate on
Hermes versions that expose the native plugin target-resolution contract.

Hermes also accepts a top-level `inline:` block for plugin-owned settings, but
`platforms.inline` matches the shape used by most Hermes platform docs and is
the safest form to copy into `~/.hermes/config.yaml`.

If you intentionally keep the token in `config.yaml` instead of the gateway
environment, set `platforms.inline.token` directly. The adapter also accepts
`inline.token` and simple `${ENV_NAME}` references in either token field,
resolving them from the process environment at runtime. Environment variables
remain the preferred production path for secrets.

Access control follows Hermes' native platform model:

| Setting | Purpose |
| --- | --- |
| `INLINE_ALLOWED_USERS` | Comma-separated Inline user ids allowed to DM the bot. Setting this also makes the adapter treat DMs as allowlisted unless `INLINE_DM_POLICY` is set. |
| `INLINE_ALLOW_ALL_USERS=true` | Explicit Hermes gateway allow-all switch for Inline. Use only for trusted/dev deployments. |
| `INLINE_DM_POLICY=open|allowlist|disabled` | Controls direct-message intake. `allowlist` requires `INLINE_ALLOWED_USERS` or config `allow_from`. |
| `INLINE_GROUP_POLICY=open|allowlist|disabled` | Controls group intake. `allowlist` requires `INLINE_GROUP_ALLOW_FROM`. |
| `INLINE_GROUP_ALLOW_FROM` | Comma-separated Inline user ids allowed to invoke the bot from group chats. |
| `INLINE_REQUIRE_MENTION` | Requires a mention or wake word in groups by default. Replies to the bot and dialogs already marked `FOLLOWING` are accepted without the wake word. |
| `INLINE_STRICT_MENTION` | Requires a mention or wake word on every group turn, including replies to the bot and followed threads. Defaults to `false`. |
| `INLINE_ALLOWED_CHATS` | Comma-separated group/thread chat ids where the bot may respond. Parent chat ids also match their Inline reply threads. DMs are not filtered. Empty means no chat restriction. |
| `INLINE_FREE_RESPONSE_CHATS` | Comma-separated group/thread chat ids where no mention is required. Parent chat ids also match their Inline reply threads. Useful for dedicated agent rooms. |
| `INLINE_REPLY_THREADS` | Controls top-level reply-thread creation. `auto` creates a child reply thread only for an explicit thread request; `on` always creates; `off` stays flat. Existing child-thread conversations always remain in their thread. Defaults to `auto`. |
| `INLINE_CONTEXT_BACKFILL` | Automatic context mode. `selective` is the default, `off` disables automatic history windows, and `always` restores recent-history backfill on every turn. |
| `INLINE_THREAD_CONTEXT_LIMIT` | Max current chat/thread messages for selective thread or mention-gap context. Must be `0` through `100`; defaults to `30`. |
| `INLINE_REPLY_CONTEXT_LIMIT` | Max messages in the anchored window around a replied-to Inline message. Must be `0` through `50`; defaults to `10`. |
| `INLINE_OBSERVED_CONTEXT_LIMIT` | Max unmentioned group messages kept in the observed-context buffer. Must be `0` through `100`; defaults to `20`. |
| `INLINE_OBSERVE_UNMENTIONED_MESSAGES` | Buffers unmentioned group messages that pass chat/user policy but do not wake the bot. Defaults to `true`; set to `false` to disable. |
| `INLINE_CONTEXT_HISTORY_LIMIT` | Legacy compatibility shortcut. `0` maps to `INLINE_CONTEXT_BACKFILL=off`; `1` through `20` maps to `always` with that thread-context limit. Prefer the explicit settings above. |
| `INLINE_SETTINGS_PATH` | JSON settings file for per-chat `/threads` overrides. Defaults next to `INLINE_STATE_PATH`; `.env`-like paths are refused. SDK state and settings have exclusive writer locks and account/API ownership tags. A tagged file cannot be reused by another bot or API endpoint. Untagged legacy files retain their contents; keep their original configured profile because their prior owner cannot be reconstructed. |
| `INLINE_SYSTEM_EVENTS` | Delivers Inline lifecycle events such as edits, deletes, and participant changes as synthetic messages. Defaults to `false`. Reactions on bot messages are always delivered. |
| `INLINE_REACTIONS` | Shows 👀 while Hermes handles an inbound message, then ✅ on success or ❌ on failure. Cancellation clears the working marker. Defaults to `false`. |
| `INLINE_MENTION_PATTERNS` | JSON list, comma-separated, or newline-separated regex patterns for group wake words. |
| `INLINE_PARSE_MARKDOWN` | Controls whether supported outbound Inline Markdown is parsed. Defaults to `true`; `false` preserves the supplied syntax literally. |
| `INLINE_SYNC_COMMANDS` | Syncs Hermes slash commands into Inline's native `/` bot command menu on gateway connect. Defaults to `true`. |
| `INLINE_COMMAND_LIMIT` | Caps native Inline bot command sync. Must be `1` through `100`; defaults to `100`. |
| `INLINE_MEDIA_MAX_MB` | Maximum inbound media download size for URL-backed Inline attachments. Defaults to `25`. |
| `INLINE_UPLOAD_MAX_MB` | Maximum outbound local file upload size. The Python adapter and Node sidecar both enforce it before upload bytes are read. Defaults to `300`. |
| `INLINE_STATE_PATH` | Persistent Inline SDK state file. Defaults under the owning Hermes profile's `inline/sdk-state.json`. Separate served profiles keep separate checkpoints and settings. One-shot sends use a stateless transport and cannot update the live receiver's files. |
| `INLINE_RPC_TIMEOUT_MS` | Realtime RPC timeout for the Node sidecar. |
| `INLINE_CONNECT_TIMEOUT_MS` | Adapter startup timeout while waiting for the sidecar to become realtime-ready. Defaults to `20000`. |
| `INLINE_CONNECT_RETRY_INITIAL_MS` | Initial sidecar retry delay after realtime startup failure. Defaults to `1000`. |
| `INLINE_CONNECT_RETRY_MAX_MS` | Maximum sidecar retry delay after repeated realtime startup failures. Defaults to `15000`. |
| `INLINE_SIDECAR_PORT` | Optional fixed loopback port from `1` through `65535`. Managed sidecars otherwise ask the kernel for a free listener, preventing default-profile collisions. Standalone send transports use their own listener. |
| `INLINE_SIDECAR_AUTOSTART` | Defaults to `true`. Receiving requires the managed sidecar so its state writer and lifecycle have one owner. `false` is supported only for send-only fallback using an externally supervised endpoint; external receiving fails before reporting connected. |
| `INLINE_SIDECAR_BIND` | Sidecar bind host. Must be loopback: `127.0.0.1`, `localhost`, or `::1`. Defaults to `127.0.0.1`. |
| `INLINE_HERMES_SENTRY_DSN` | Explicitly enables adapter and sidecar error reporting to the configured collector. Reporting is disabled when unset. |
| `INLINE_PLUGIN_TELEMETRY` | Set to `off`, `0`, or `false` to disable explicitly configured plugin error reporting. `DO_NOT_TRACK=1` is also honored. |
| `platforms.inline.typing_indicator` | Hermes-native toggle for Inline typing/presence while a turn is running. Defaults to `true`; set to `false` to keep busy threads visually quiet. |
| `platforms.inline.gateway_restart_notification` | Hermes-native toggle for gateway online/restarted notices. Defaults to `true`. |

Policy is evaluated in three ordered stages: **access**, then **wake**, then **delivery**. Access checks the chat and sender policy and is a hard gate; a mention, reply, callback, or command never grants access to a blocked chat or actor. Wake decides whether an allowed group turn invokes Hermes: free-response chats wake normally, while mention-gated chats require an explicit mention unless a configured reply-to-bot or followed-thread exception applies. Delivery keeps existing child-thread conversations in place; top-level `auto` creates a child only for explicit thread intent, `on` always creates one, and `off` stays flat.

`open` controls intake; it does not grant permission to use the bot. After
Inline's sender and group/thread restrictions pass, the adapter asks Hermes'
registered authorization callback before executing local commands, creating
reply threads, downloading media, collecting context, or exposing runtime
settings. This uses the same pairing and profile-aware authorization as native
Hermes adapters. An unapproved sender reaches Hermes' pairing or rejection
flow with a minimal text event and no preceding adapter mutations or media work.
Pairing approval does not override an explicit Inline allowlist, disabled
policy, or excluded group. DMs remain exempt from `allowed_chats`.
Child-thread authorization preserves both the child and parent chat IDs so
Hermes can select the correct profile. If required group metadata is unavailable,
the adapter denies the operation instead of guessing a profile. Controls that
change the parent's reply-thread mode also require access to that parent;
thread-local model and following settings remain available to an authorized
child-thread user.

Reply threads keep one Hermes identity from the opening turn through later
child-chat turns. A group reply thread keys on the child chat and thread ID;
a DM reply thread keys on its immediate parent chat and thread ID. DM policy
follows nested parent edges to the root DM, while Inline transport targets and
message IDs retain their actual chat. Unavailable or malformed ancestry cannot
fall through to group policy. Root chats and sibling threads remain separate.

For workflows that use a pinned bot DM for casual exchanges and explicitly
created conversations for tasks, set `reply_threads: off`. The `create_thread`
tool and Inline's new-chat flow remain available. Scheduled delivery does not
automatically create another Inline subthread; Hermes owns transcript attachment
and CLI handoff identity, which need separate host validation.

Default SDK state, chat settings, and downloaded media use the active Hermes
profile home. Explicit `state_path` and `settings_path` continue to take priority.
An upgrade does not move previously shared files into named profiles; review
per-chat `/threads` overrides when moving from the old shared defaults.

Equivalent Hermes YAML can use `allow_from`, `allowed_users`,
`group_allow_from`, `dm_policy`, `group_policy`, `require_mention`,
`strict_mention`, `allowed_chats`, `free_response_chats`, `reply_threads`,
`context_backfill`, `thread_context_limit`, `reply_context_limit`,
`observed_context_limit`, `observe_unmentioned_messages`, `settings_path`, and
`mention_patterns`, and `reactions` under the Inline platform config. Operational settings such
as `base_url`, `parse_markdown`, `media_max_mb`, `upload_max_mb`,
`state_path`, `sidecar_port`, `connect_timeout_ms`, `sync_commands`, and
`command_limit` can also be set there.
Prefer Hermes YAML for behavioral settings. Environment variables remain supported for compatibility and secret-backed deployment inputs.
Use a JSON list for mention regexes that contain commas, for example
`["hermes\\b[:,]?"]`.

Inline also supports Hermes' native thread/channel prompt and skill bindings.
Use raw Inline chat/thread ids for these bindings. Inline reply-thread chats
are checked first, then their parent chat id:

```yaml
platforms:
  inline:
    channel_prompts:
      "123": "Treat this Inline thread as the customer escalation room."
    channel_skill_bindings:
      - id: "123"
        skills: ["support-triage", "incident-report"]
```

Inline-native button callbacks, including approvals, clarify choices,
model pickers, and thread controls, use the same local restrictions and Hermes
authorization callback. Pairing-approved users can use them without a second
Inline allowlist. A denial, error, or unknown result from a registered callback
blocks the action. Only standalone adapters without a registered callback use
explicit Inline/global allowlists or allow-all settings as a fallback; `open`
alone never authorizes controls. Settings requests from unauthorized users show
an access guide without runtime or model information.
Adapter-owned controls use `system:` action IDs and stay in these deterministic
handlers. Agent-authored callbacks use `agent:` IDs and follow the ordinary
message intake policy because they are conversational input, not approval or
gateway-control input. Callback data is always presented to the model as
untrusted data and cannot become a Hermes slash command.

On gateway startup, the adapter derives the Inline `/` menu from Hermes'
declarative local command registry plus Hermes' central slash-command registry,
normalizes names to Inline Bot API constraints
(`^[a-z0-9_]+$`, max 32 characters), and calls `setMyCommands`. If Inline
rejects the full list with `BOT_COMMANDS_TOO_MUCH`, the adapter retries with a
smaller prefix. Menu sync failures are logged as warnings and do not prevent
message transport; `/commands` remains the full fallback list. In chats with
multiple bots, Inline may insert `/command@botusername` to disambiguate a menu
choice. Hermes accepts that form only when the suffix matches its own username,
then removes the suffix before command dispatch; commands addressed to another
bot are ignored.

Plugin updates are managed on the Hermes host. For a catalog installation, use
`hermes plugins update inline-platform` after a new reviewed catalog pin is
available, then restart the gateway. For an npm installation:

```sh
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
```

Restart the gateway after refreshing the plugin. Version 0.0.19 removes the
in-chat updater so the same plugin can comply with the catalog's exact-commit
trust policy. Hermes's own `/update` command is unchanged.

Run `/follow` in an Inline DM, group, or reply thread to explicitly opt into
eligible unmentioned activity waking Hermes. Run `/unfollow` to explicitly opt
out; server auto-follow heuristics will not turn following back on, while
mentions and replies retain their normal relevance behavior. If an otherwise
implicit follow/reply wake begins with a concrete mention of another person,
Hermes treats that explicit address as higher priority and does not respond
unless the bot is also explicitly mentioned.

The model-callable `inline` tool keeps reply and top-level creation separate:
`create_thread` creates a reply subthread under the current or explicit parent
chat, while `create_chat` creates a new top-level destination. `create_chat`
requires a title, defaults to private with the verified person making the request, accepts explicit participant user IDs or
a parent space ID, and requires both `space_id` and explicit `is_public: true`
for space-wide visibility. It returns the new chat ID so Hermes can link it in
the normal reply.
An explicit empty `participant_user_ids: []` creates a bot-only chat. Outside a
verified human Inline turn, provide explicit participants; an automated request
does not infer or invite the bot's owner.

`add_participant` and `remove_participant` take a separate
`participant_user_id`; `rename_chat` changes only the title. These operations
use the bot's current server permissions. `delete_chat` permanently deletes
one selected chat when server permissions and parent constraints permit, so it requires an explicit
`chat_id` and a user deletion request. Closing a chat remains a separate dialog
action.

`generate_chat_emojis` accepts one to five explicit `chat_ids`. It preserves
titles and existing emojis, skips anchored reply threads, and returns one
outcome per chat. `emoji_present` means an emoji was observed afterward;
`unchanged` includes an empty provider result. A `failed` outcome carries the
server or transport error and available current metadata. Inspect these results
before retrying a partial or uncertain request.

Inside a reply thread, pass `parent_chat_id` explicitly to `create_thread`.
Omit `parent_message_id` for an unanchored child, or pass the exact parent
chat/message pair for an anchored reply thread. Message IDs are scoped to their
chat: edit, delete, reaction, and pin actions in a reply thread require an
explicit destination and message ID. The per-turn context provides the actual
triggering pair, even when the opening message belongs to the parent chat.

The plugin id is `inline`, which is intentionally the same id an eventual
bundled Hermes adapter should use.

## Error Reporting And Privacy

The Inline adapter and its supervised sidecar keep error reporting disabled
unless the operator sets `INLINE_HERMES_SENTRY_DSN` to an explicit collector.
When enabled, reports include the raw exception type and message, traceback
paths, line/function locations, plugin release,
operation name, runtime, OS, and architecture so maintainers can diagnose
failures in subsequent releases.

Reports do not attach Inline or Hermes message events, request bodies,
user/chat/account identifiers, breadcrumbs, source context, or stack locals.
Known token, password, authorization, sidecar credential, and secret-shaped
values are redacted before upload. Inline's Sentry project also enables default
server-side data scrubbing and IP-address scrubbing. Because dependency
exception messages are preserved for diagnosis, they can still contain values
the dependency itself chose to place in an error.

Remove `INLINE_HERMES_SENTRY_DSN`, set `INLINE_PLUGIN_TELEMETRY=off`, or set
`DO_NOT_TRACK=1` to disable both adapter and sidecar reporting. Reporting is
best-effort, has a two-second network deadline, and never changes plugin success
or failure behavior.

## Troubleshooting

Run `inline-hermes doctor --json` first. It checks the installed plugin path,
required files, Node executable, source/installed sidecar bundle hashes, and
whether an Inline token is available to Hermes.

`hermes inline status --json --probe --check-compatibility` separates credential/send
readiness (`ready`), host receiving support (`receivingCapability.supported`) and
the connected gateway (`gateway.ready`). A successful doctor confirms prerequisites;
only the gateway projection and an actual reply establish running delivery.

- `plugin is not installed`: run `inline-hermes install`.
- `Hermes plugin 'inline-platform' is not enabled`: run
  `hermes plugins enable inline-platform`.
- `installed sidecar bundle does not match`: re-run
  `inline-hermes install --force` after upgrading this package.
- `node executable was not detected`, `INLINE_NODE_BIN does not exist`, or
  `must be Node.js >=20`: install Node.js 20+ or set `INLINE_NODE_BIN` to the
  Node executable Hermes should use.
- `SESSION_REVOKED` during `test-send`: the Inline token reached the realtime
  service but was rejected. Re-authenticate or rotate the bot/user token and
  retry.
- `sidecar was not ready`: inspect the JSON `health` and `logs` fields from
  `test-send --json`; token, base URL, or realtime startup failures are exposed
  there with retry diagnostics.
- `INLINE_SIDECAR_BIND must be loopback`: remove the override or set it to
  `127.0.0.1`, `localhost`, or `::1`. The sidecar intentionally refuses
  externally reachable bind addresses even though its HTTP API is token-gated.

### Candidate runtime qualification

Receiving in this candidate requires the matching Hermes durable-intake core
patch: `BasePlatformAdapter.durable_intake_version == 1` and profile handlers
wired by the gateway. An unpatched or unwired host refuses receiving at startup
with `DURABLE_INTAKE_REQUIRED`; standalone send-only delivery remains available.
The historical minimum host version is a plugin loader/send-only compatibility
floor, and does not prove this receiving contract.

The profile StateDB adopts one immutable authenticated input before the SDK ACK.
The ordinary user-row transaction consumes its receipt before a provider request.
Restart rechecks the receiving bot, API/profile, current source access, authored
revision, recipient/Agent policy and canonical route. It reconstructs context
from current public messages, without serializing private provider history.
Completed controls use the synchronous handler disposition and are excluded from
automatic receipt replay. Model-directed buttons and reactions have independent
interaction/update identities and revalidate their referenced public message.

### Cron continuation qualification

The Jack workflow candidate is adapter 0.0.22 paired with the reviewed fork's
core changes for durable intake, public-context admission and worker-owned cron.
A release number or the historical plugin-loader floor does not establish those
capabilities. `delivery_source_resolver` resolves the same logical root/child
source as a follow-up under the owning profile's current authorization and sharing
policy. Adapter installation alone does not supply these core changes.

The worker runs its cron in an independent scratch session and posts its confirmed
output into the intended public task chat. Its next ordinary authorized input
admits the currently visible output once, alongside other public history. Cron and
generic send tools do not also seed or mirror private transcripts on this path.
The actual current source, reset boundary and accepted public revisions determine
continuation, rather than an older sender-matching private transcript. A confirmed
visible message is never resent to repair attachment. An unavailable owning route
fails before sending; temporary unavailability at follow-up admission retains the
input for retry. Legacy hosts without public admission retain their separate
canonical attachment/mirror behavior and diagnostic warnings.

No transcript merge or legacy shared-file migration is performed. Named profiles
without explicit path overrides start from their configured `/threads` default;
new per-profile overrides persist across restart. Legacy SDK/settings files remain
unchanged. Configure explicit paths when deliberately retaining old state, and
back up those files before changing existing profile paths.

Chief may seed an authorized task and ask its configured worker to own the cron.
The matching core also supports an explicit configured executor profile; this
selects execution ownership without expanding chat access or copying private
history. Conversation promotion, title ownership and Apple client behavior use
Inline's own product primitives and are qualified in their separate slices.
Real post-restart provider/cron/follow-up acceptance is required before handing
this candidate to Jack.

Receiving qualification installs the exact `inlineHermes.testedHermesCommit`
from `inlineHermes.testedHermesRepository` (`morajabi/hermes-agent`) in the existing
real-server CI lane. The core is reviewed and pushed; this pin still requires
qualification with the exact packaged adapter and Inline source. The installer
preserves source ancestry and tags for the actual version, and builds PM-capable
hosts through their own `pm.build_env` into an isolated environment. Official
Hermes tag/latest/main checks continue to qualify plugin loading, tools, offline
sends and actionable receive refusal without a wired durable-intake gateway.

A successful receiving receipt binds the actual imported core repository/SHA
and intake version 1 to the Inline source commit and exact adapter tarball hash.
Publication requires that receipt from successful trusted-main CI and rejects
different release bytes. A differing repack must receive its own real-server
qualification; stock compatibility checks cannot substitute. This lane proves
native adoption, user-row consumption and one persisted reply with a deterministic
handler. Live provider, process-death recovery and deployed service acceptance
retain their separately stated tests and limits.
