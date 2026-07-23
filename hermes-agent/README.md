# @inline-chat/hermes-agent-adapter

Inline platform plugin for Hermes Agent.

This package installs an external Hermes platform plugin named `inline` and a
supervised Node sidecar that uses `@inline-chat/realtime-sdk` for Inline
realtime transport.

Implemented Hermes-native surfaces:

- realtime inbound messages, replies, and action callbacks
- outbound text, markdown, opt-in edit-message streaming, deletes, typing, media uploads, and reply threads
- Discord-style native Hermes `inline` tool for bounded chat/message/history/search/thread, reaction, and pin actions
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
- Outbound text, Markdown parsing, opt-in edit-message streaming, long-message splitting, edits, deletes, typing, and presence.
- Inline reply-thread routing, explicit-request auto mode, `/threads` controls, parent chat metadata, parent/thread prompt fallback, and thread-specific skill bindings.
- Native Hermes `inline` tool for current-chat/thread reads, bounded history and search, exact message lookup, editing/deleting bot-owned messages, reactions, pin/unpin/list pins, reply-thread creation, and avatar presence/status.
- Per-turn Inline sender/chat/thread IDs, selective reply/thread/observed context, and parent-thread context, with prompt guidance for sender mentions and current chat/thread Markdown links.
- OpenClaw-style entity summaries for live turns and tool-fetched history, including mentions, text links, thread links, thread-title links, code/pre blocks, bot commands, and group mentions as untrusted Hermes context.
- DM and group policies, user allowlists, group sender allowlists, mention requirements, strict mention mode, allowed chats, and free-response chats.
- Native Inline `/` command-menu sync for Hermes slash commands, including `/threads` and `/update`; typed slash commands continue to work even if menu sync is disabled or rejected.
- Inline-native buttons for clarify prompts, command approvals, slash confirmations, and model selection.
- Outbound local photo, video, voice, and document uploads with configurable size caps.
- Inbound photo, video, voice, and document summaries, with URL-backed media cached locally for Hermes when available.
- Reactions on bot messages, plus opt-in lifecycle/system events as synthetic Hermes messages.
- Cron or standalone sends through `INLINE_HOME_CHANNEL` and `hermes send --to inline:<chat-id>`.
- Hermes-native `typing_indicator` and `gateway_restart_notification` toggles, with plugin-owned YAML bridge coverage for external-plugin compatibility.

Unsupported or intentionally limited:

- Multiple Inline accounts in one Hermes process. Run separate Hermes instances for separate tokens.
- Inline member, space, and admin tools beyond bounded current-chat/thread message access.
- Full Inline rich-text span conversion. Outbound formatting uses Inline Markdown parsing; rich entities are summarized for the agent instead of converted into Hermes-specific spans.
- Native animated draft streaming. Inline can stream by sending one preview message and editing it, but this edit-based streaming path is off by default like Discord and Slack.
- Ephemeral in-channel private replies. Private notices are sent as DMs when a user id is available.
- Live voice sessions or calls. Voice file messages are supported, but realtime audio is not.
- Media without a usable Inline CDN/local URL. Those messages still produce text summaries, but Hermes may not receive a local file path.

## Install

```sh
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
```

Need a bot token first? Use the [Inline bot creation guide](https://inline.chat/docs/creating-a-bot).

## Coding Agent Setup Prompt

Use this with Codex, Claude Code, or another local coding agent when you want a
one-shot setup:

```text
Set up the Inline Hermes Agent adapter on this machine.

Constraints:
- Do not read, print, or edit .env files.
- Do not print Inline tokens or other secrets.
- Use an Inline token from INLINE_TOKEN or INLINE_BOT_TOKEN; if neither is present, stop and point me to https://inline.chat/docs/creating-a-bot.

Tasks:
1. Verify Node.js is version 20 or newer and Hermes Agent is installed.
2. Install or upgrade @inline-chat/hermes-agent-adapter globally.
3. Run inline-hermes install and hermes plugins enable inline-platform.
4. Ensure ~/.hermes/config.yaml enables platforms.inline, using token: ${INLINE_TOKEN} if config needs an env reference.
5. Run inline-hermes doctor --json and inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json.
6. Report the exact commands run and any remaining manual steps, without revealing secrets.
```

For local development:

```sh
cd hermes-agent
bun run build
node dist/install.js install --link --hermes-home ~/.hermes
cd ~/dev/hermes-agent
uv run ./hermes plugins enable inline-platform
```

Check an installation:

```sh
inline-hermes doctor --json
hermes inline status
inline-hermes --version
```

`doctor` verifies required plugin files, the Node executable used for the
sidecar, the installed sidecar bundle hash, and whether Hermes config enables
the external plugin with `plugins.enabled: [inline-platform]`. It honors
`INLINE_NODE_BIN` and fails if that explicit path is missing, not executable,
older than Node 20, or cannot report a Node version. It also fails if a copied
plugin has drifted from the package bundle.

Confirm Hermes sees the plugin:

```sh
cd ~/dev/hermes-agent
uv run ./hermes plugins list --plain --no-bundled
```

Expected local output includes:

```text
enabled      user     0.0.5    inline-platform
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

- Hermes Agent: requires the external user plugin registry and native platform
  plugin loader available in Hermes Agent `0.17.x`. This package was validated
  against Hermes Agent `0.18.2` from source commit `9de9c25`.
- Node.js: `>=20` is required for the bundled sidecar. Hermes-managed Node 22,
  system Node, or an explicit `INLINE_NODE_BIN` path all work.
- Inline transport: the sidecar uses `@inline-chat/realtime-sdk@0.0.13` and is
  bundled into the npm package, so Hermes startup does not run `npm install`.
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

This runs `npm publish --dry-run --access public`. npm invokes
`prepublishOnly`, so the dry-run must pass `bun run check`, rebuild the packed
runtime files, verify the shipped `inline-hermes` binary, and print the final
tarball contents without publishing.

Maintainers should also run the manual live-test and publish checklist in
[`hermes-agent/RELEASE.md`](https://github.com/inline-chat/inline/blob/main/hermes-agent/RELEASE.md).

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
| `INLINE_REQUIRE_MENTION` | Requires a mention or wake word in groups by default. Replies to the bot and followed eligible reply/fresh threads are accepted without the wake word. |
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
| `INLINE_SETTINGS_PATH` | JSON settings file for per-chat `/threads` overrides. `/threads` shows native Auto/On/Off buttons; `reset` clears the chat override back to the global default. Defaults next to `INLINE_STATE_PATH`; `.env`-like paths are refused. |
| `INLINE_SYSTEM_EVENTS` | Delivers Inline lifecycle events such as edits, deletes, and participant changes as synthetic messages. Defaults to `false`. Reactions on bot messages are always delivered. |
| `INLINE_MENTION_PATTERNS` | JSON list, comma-separated, or newline-separated regex patterns for group wake words. |
| `INLINE_PARSE_MARKDOWN` | Controls whether outbound Hermes Markdown is parsed by Inline. Defaults to `true`. |
| `INLINE_SYNC_COMMANDS` | Syncs Hermes slash commands into Inline's native `/` bot command menu on gateway connect. Defaults to `true`. |
| `INLINE_COMMAND_LIMIT` | Caps native Inline bot command sync. Must be `1` through `100`; defaults to `100`. |
| `INLINE_MEDIA_MAX_MB` | Maximum inbound media download size for URL-backed Inline attachments. Defaults to `25`. |
| `INLINE_UPLOAD_MAX_MB` | Maximum outbound local file upload size. The Python adapter and Node sidecar both enforce it before upload bytes are read. Defaults to `300`. |
| `INLINE_STATE_PATH` | Persistent Inline SDK state file. Defaults to `~/.hermes/inline/sdk-state.json`. |
| `INLINE_RPC_TIMEOUT_MS` | Realtime RPC timeout for the Node sidecar. |
| `INLINE_CONNECT_TIMEOUT_MS` | Adapter startup timeout while waiting for the sidecar to become realtime-ready. Defaults to `20000`. |
| `INLINE_CONNECT_RETRY_INITIAL_MS` | Initial sidecar retry delay after realtime startup failure. Defaults to `1000`. |
| `INLINE_CONNECT_RETRY_MAX_MS` | Maximum sidecar retry delay after repeated realtime startup failures. Defaults to `15000`. |
| `INLINE_SIDECAR_PORT` | Fixed loopback port for the sidecar. Must be `1` through `65535`. Defaults to `8794`; `test-send` uses a random free port. |
| `INLINE_SIDECAR_BIND` | Sidecar bind host. Must be loopback: `127.0.0.1`, `localhost`, or `::1`. Defaults to `127.0.0.1`. |
| `platforms.inline.typing_indicator` | Hermes-native toggle for Inline typing/presence while a turn is running. Defaults to `true`; set to `false` to keep busy threads visually quiet. |
| `platforms.inline.gateway_restart_notification` | Hermes-native toggle for gateway online/restarted notices. Defaults to `true`. |

Policy is evaluated in three ordered stages: **access**, then **wake**, then **delivery**. Access checks the chat and sender policy and is a hard gate; a mention, reply, callback, or command never grants access to a blocked chat or actor. Wake decides whether an allowed group turn invokes Hermes: free-response chats wake normally, while mention-gated chats require an explicit mention unless a configured reply-to-bot or followed-thread exception applies. Delivery keeps existing child-thread conversations in place; top-level `auto` creates a child only for explicit thread intent, `on` always creates one, and `off` stays flat.

Equivalent Hermes YAML can use `allow_from`, `allowed_users`,
`group_allow_from`, `dm_policy`, `group_policy`, `require_mention`,
`strict_mention`, `allowed_chats`, `free_response_chats`, `reply_threads`,
`context_backfill`, `thread_context_limit`, `reply_context_limit`,
`observed_context_limit`, `observe_unmentioned_messages`, `settings_path`, and
`mention_patterns` under the Inline platform config. Operational settings such
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

Inline-native button callbacks, such as approvals and clarify choices, require
the clicking actor to pass an explicit Inline or global Hermes allowlist, or
`INLINE_ALLOW_ALL_USERS=true` / `GATEWAY_ALLOW_ALL_USERS=true`. This includes
model-picker callbacks. The stricter callback gate prevents group-visible
buttons from becoming a bypass when message intake is otherwise `open`.

On gateway startup, the adapter derives the Inline `/` menu from Hermes'
central slash-command registry, normalizes names to Inline Bot API constraints
(`^[a-z0-9_]+$`, max 32 characters), and calls `setMyCommands`. If Inline
rejects the full list with `BOT_COMMANDS_TOO_MUCH`, the adapter retries with a
smaller prefix. Menu sync failures are logged as warnings and do not prevent
message transport; `/commands` remains the full fallback list.

The plugin id is `inline`, which is intentionally the same id an eventual
bundled Hermes adapter should use.

## Troubleshooting

Run `inline-hermes doctor --json` first. It checks the installed plugin path,
required files, Node executable, and source/installed sidecar bundle hashes.

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
