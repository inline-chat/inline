# Hermes Agent

Use the Inline adapter to run Hermes Agent from Inline DMs, group chats, and reply threads.

Need a bot token first? See [Creating a Bot](/docs/creating-a-bot).

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
```

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
4. Ensure ~/.hermes/config.yaml enables platforms.inline, using token: ${INLINE_TOKEN} if config needs an env reference.
5. Run inline-hermes doctor --json and inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json.
6. Report the exact commands run and any remaining manual steps, without revealing secrets.
```

## Configure

Set the token where the Hermes gateway runs:

```bash
export INLINE_TOKEN="<INLINE_BOT_TOKEN>"
```

Enable Inline in `~/.hermes/config.yaml`:

```yaml
platforms:
  inline:
    enabled: true
```

If Hermes cannot read environment variables directly, reference the token in config:

```yaml
platforms:
  inline:
    enabled: true
    token: ${INLINE_TOKEN}
```

## Verify

Check the plugin install:

```bash
inline-hermes doctor --json
hermes inline status
inline-hermes --version
```

Validate wiring without sending a message:

```bash
inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json
```

Send a real message after replacing the chat ID:

```bash
inline-hermes test-send --to chat:123 --text "Inline Hermes test"
```

Hermes' built-in send command uses the `inline:<chat-id>` target form:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

## Update

After upgrading the npm package, refresh the Hermes plugin copy:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
inline-hermes doctor --json
```

This replaces installed plugin files. It does not edit tokens or `~/.hermes/config.yaml`.

## Configuration

Inline uses quiet work-chat defaults: typing/presence while Hermes is working, final answers in chat, and no durable tool-call progress bubbles.

If global Hermes config enables progress messages, keep Inline quiet with:

```yaml
display:
  platforms:
    inline:
      tool_progress: off
      cleanup_progress: true
      streaming: false
      interim_assistant_messages: false
```

## Feature Support

Supported:

- DMs, group chats, reply threads, and `hermes send --to inline:<chat-id>`.
- Realtime inbound messages, replies, edits, deletes, typing, presence, long replies, and media uploads.
- Inline-native clarify, approval, slash confirmation, model picker, and command-menu sync.
- Native Hermes `inline` tool for bounded current-chat/thread history and search, exact message lookup, reactions, pins, typing/presence, and reply-thread creation.
- Selective reply/thread/observed context, sender IDs, parent-thread context, and Inline entity summaries.
- Allowlists, mention controls, thread prompts, skill bindings, and reply-thread routing.

Unsupported or intentionally limited:

- Multiple Inline accounts in one Hermes process.
- Full Inline member, space, and admin tools beyond bounded current-chat/thread message access.
- Full rich-text span conversion. Rich entities are summarized for the agent.
- Native animated draft streaming.
- Ephemeral in-channel private replies or realtime voice/calls.

## Advanced

- Requires Hermes Agent `0.17.x` and Node.js `20` or newer.
- Tokens are read from `INLINE_TOKEN`, `INLINE_BOT_TOKEN`, `platforms.inline.token`, or `inline.token`.
- Room controls are available through `INLINE_ALLOWED_CHATS`, `INLINE_FREE_RESPONSE_CHATS`, and `INLINE_STRICT_MENTION`. Parent chat ids also match Inline reply threads.
- Top-level DM and group replies use Inline reply threads by default. Use `/threads on`, `/threads off`, or `/threads auto` in Inline to configure a chat, or set `INLINE_REPLY_THREADS=false` globally.
- Thread-specific prompts and skill bindings are supported through `platforms.inline.channel_prompts` and `platforms.inline.channel_skill_bindings`; Inline checks the thread chat id first, then the parent chat id.
- Set `platforms.inline.typing_indicator: false` if Inline rooms should stay visually quiet while Hermes is thinking.
- Set `display.platforms.inline.tool_progress: off` to suppress tool-call progress messages. If you opt into progress, keep `display.platforms.inline.cleanup_progress: true` so successful runs do not leave progress bubbles behind.
- Slash commands typed as text always work; the native `/` menu is synced on gateway connect and can be disabled with `INLINE_SYNC_COMMANDS=false` or `platforms.inline.sync_commands: false`.
- `SESSION_REVOKED` means the token reached Inline realtime but is expired or revoked.
- Missing-token diagnostics mean the Hermes gateway needs `INLINE_TOKEN`/`INLINE_BOT_TOKEN`, or `platforms.inline.token`/`inline.token` in config.
- Source and package docs live in the [public Inline repo](https://github.com/inline-chat/inline/tree/main/hermes-agent).
