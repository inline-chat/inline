# Hermes Agent

Install the official Inline platform adapter for Hermes Agent.

## Requirements

- Hermes Agent `0.17.x`
- Node.js `20` or newer
- The Inline CLI for guided bot creation, or an existing Inline bot/user token

The setup wizard can create and configure the bot for you. Manual bot creation
is also available in [Creating a Bot](https://inline.chat/docs/creating-a-bot).

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
hermes gateway setup
```

Select **Inline** in the messaging-platform picker. The default path is: go to
**Inline → Settings → Bots → Create a new bot**, then paste its token. The
optional CLI path can install/sign in to the Inline CLI and create the bot from
the terminal. Both paths save the token through Hermes' credential helper and
configure access.

## Coding Agent Setup Prompt

Use this with Codex, Claude Code, or another local coding agent for a simple setup:

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
4. Run hermes gateway setup and select Inline. Prefer its guided bot-creation path; if no Inline token is available, let this interactive wizard ask the user to sign in or paste one.
5. Run inline-hermes doctor --json and inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json.
6. Report the exact commands run and any remaining manual steps, without revealing secrets.
```

## Manual configuration

The guided setup above is the default. For headless deployments or managed
environments, configure the same values manually:

Set the token in the Hermes gateway environment:

```bash
export INLINE_TOKEN="<INLINE_BOT_TOKEN>"
```

Enable the Inline platform in `~/.hermes/config.yaml`:

```yaml
platforms:
  inline:
    enabled: true
```

Inline uses work-chat defaults: typing/presence while Hermes is working, final
answers in chat, and no durable tool-call progress bubbles. If your Hermes
config has global tool progress enabled, add this per-platform override:

```yaml
display:
  platforms:
    inline:
      tool_progress: off
      cleanup_progress: true
      streaming: false
      interim_assistant_messages: false
```

If a process manager cannot inject the token directly, Hermes config can point
to an environment variable without storing the token in the file:

```yaml
platforms:
  inline:
    enabled: true
    token: ${INLINE_TOKEN}
```

## Verify

```bash
inline-hermes doctor --json
hermes inline status
inline-hermes --version
inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json
```

With a real target and a token in the environment or Hermes config:

```bash
export INLINE_TOKEN="<INLINE_BOT_TOKEN>"
inline-hermes test-send --to chat:123 --text "Inline Hermes test"
```

Hermes' generic send command uses the `inline:<chat-id>` target form:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

## Update

After upgrading the npm package, refresh the Hermes plugin copy:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
inline-hermes --version
inline-hermes doctor --json
```

This does not edit `~/.hermes/config.yaml` or tokens. It only replaces the
installed plugin files and verifies the bundled sidecar hash.

## Feature Support

Supported:

- DMs, group chats, Inline reply threads, and `hermes send --to inline:<chat-id>`.
- Token setup through `INLINE_TOKEN`, `INLINE_BOT_TOKEN`, `platforms.inline.token`, or `inline.token`, including simple `${ENV_NAME}` config references.
- Realtime inbound messages, catch-up, replies, action callbacks, opt-in edit-message streaming, edits, deletes, typing, presence, and long outbound replies.
- Inline-native clarify, approval, slash confirmation, and model picker buttons.
- Native Inline `/` command-menu sync for Hermes slash commands, including `/threads` and `/update`.
- Native Hermes `inline` tool for bounded current-chat/thread history and search, exact message lookup, sending, editing, deleting bot-owned messages, reactions, pin/unpin/list pins, typing/presence, and reply-thread creation.
- Per-turn Inline sender/chat/thread IDs, selective reply/thread/observed context, and parent-thread context, with prompt guidance for sender mentions and current chat/thread Markdown links.
- Local photo, video, voice, and document uploads; URL-backed inbound media caching when available.
- User/group allowlists, group sender allowlists, mention controls, allowed chats, free-response chats, default reply-thread routing with `/threads` controls, thread prompts, and skill bindings.
- Inline entity summaries for live turns and tool-fetched history, including mentions, text links, thread links, thread-title links, code/pre blocks, bot commands, and group mentions as untrusted Hermes context.
- Reactions on bot messages and opt-in lifecycle/system events.
- Hermes-native `typing_indicator` and `gateway_restart_notification` toggles.

Unsupported or intentionally limited:

- Multiple Inline accounts in one Hermes process.
- Full Inline member, space, and admin tools beyond bounded current-chat/thread message access.
- Full Inline rich-text span conversion. Rich entities are summarized for the agent instead of converted into Hermes-specific spans.
- Native animated draft streaming. Inline can stream by editing a preview message, but edit-based streaming is off by default like Discord and Slack.
- Ephemeral in-channel private replies or realtime voice/calls.
- Media without a usable Inline CDN/local URL. Hermes still receives a text summary, but may not receive a local file path.

## Troubleshooting

- `Hermes plugin 'inline-platform' is not enabled`: run `hermes plugins enable inline-platform`.
- Missing-token diagnostics: set a valid Inline token in the Hermes gateway environment, or configure `platforms.inline.token`/`inline.token` for the adapter.
- `SESSION_REVOKED`: the token reached Inline realtime but is expired or revoked. Create or rotate the token and retry.
- Node errors: install Node.js 20+ or set `INLINE_NODE_BIN` to the Node executable Hermes should use.
- Slash commands typed as text always work; the native `/` menu is synced on gateway connect and can be disabled with `INLINE_SYNC_COMMANDS=false` or `platforms.inline.sync_commands: false`.
- Room controls are available through `INLINE_ALLOWED_CHATS`, `INLINE_FREE_RESPONSE_CHATS`, and `INLINE_STRICT_MENTION`. Parent chat ids also match Inline reply threads.
- Top-level DM and group replies use Inline reply threads by default. Use `/threads on`, `/threads off`, or `/threads auto` in Inline to configure a chat, or set `INLINE_REPLY_THREADS=false` globally.
- Automatic context uses `INLINE_CONTEXT_BACKFILL=selective` by default: parent/reply-thread metadata, parent messages, reply windows, first thread turns, mention-gap catch-up, and observed unmentioned group context are included when relevant. Use `INLINE_THREAD_CONTEXT_LIMIT`, `INLINE_REPLY_CONTEXT_LIMIT`, `INLINE_OBSERVE_UNMENTIONED_MESSAGES=false`, or `INLINE_OBSERVED_CONTEXT_LIMIT` to tune it. Exact older history remains available through the `inline` tool.
- Thread-specific prompts and skill bindings are supported through `platforms.inline.channel_prompts` and `platforms.inline.channel_skill_bindings`; Inline checks the thread chat id first, then the parent chat id. See the package README for examples.
- Set `display.platforms.inline.tool_progress: off` to suppress tool-call progress messages. If you opt into progress, keep `display.platforms.inline.cleanup_progress: true` so successful runs do not leave progress bubbles behind.

Full package docs: [`hermes-agent/README.md`](../hermes-agent/README.md).
