# Hermes Agent

Source: https://inline.chat/docs/hermes

Use the Inline adapter to run Hermes Agent from Inline DMs, group chats, and reply threads.

Need a bot token first? See [Creating a Bot](https://inline.chat/docs/creating-a-bot).

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
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
- Bounded current-chat/thread history through the Hermes `inline` tool.
- Allowlists, mention controls, thread prompts, skill bindings, and reply-thread routing.

Unsupported or intentionally limited:

- Multiple Inline accounts in one Hermes process.
- Full Inline member, space, search, and admin tools.
- Full rich-text span conversion. Rich entities are summarized for the agent.
- Native animated draft streaming.
- Ephemeral in-channel private replies or realtime voice/calls.

## Advanced

- Requires Hermes Agent `0.17.x` and Node.js `20` or newer.
- Tokens are read from `INLINE_TOKEN`, `INLINE_BOT_TOKEN`, `platforms.inline.token`, or `inline.token`.
- Room controls are available through `INLINE_ALLOWED_CHATS`, `INLINE_FREE_RESPONSE_CHATS`, and `INLINE_STRICT_MENTION`.
- Top-level DM and group replies use Inline reply threads by default. Use `/threads on`, `/threads off`, or `/threads auto` in Inline to configure a chat, or set `INLINE_REPLY_THREADS=false` globally.
- Full adapter reference: [public Inline repo](https://github.com/inline-chat/inline/tree/main/packages/hermes-agent).
