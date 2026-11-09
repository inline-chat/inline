# Inline for Hermes Agent

Use Hermes from Inline work-chat DMs, chats, and reply threads. The plugin
connects Hermes to Inline through a bundled Node.js sidecar; it does not install
npm packages when the gateway starts.

## Requirements

- Hermes Agent 0.21.3 or newer.
- Node.js 20 or newer, available on the gateway host.
- An Inline bot token. [Create a bot](https://inline.chat/docs/creating-a-bot),
  or use the guided setup below.

## Install and configure

Once this entry is available in the Hermes catalog:

```sh
hermes plugins install inline-platform
hermes plugins enable inline-platform
hermes gateway setup
```

Select **Inline** in gateway setup. It can guide you through bot creation or
accept an existing token using Hermes's credential storage. Keep tokens out of
chat messages and command-line arguments.

Check configuration and plugin compatibility:

```sh
hermes inline status --json --check-compatibility
hermes inline status --json --probe
hermes gateway status
```

Start or restart the Hermes gateway through your usual service manager, then
send the bot a DM in Inline. A successful status probe alone does not prove
inbound message delivery; confirm that the bot replies.

## Using the plugin

- `/threads` configures reply-thread routing.
- `/follow` and `/unfollow` control explicit chat following.
- `/inline_sync` republishes Hermes commands and skills to Inline.
- `/inline_version` reports the loaded plugin version and last catalog sync.

The agent can send sandboxed HTML message widgets (charts, diagrams, small
pickers) with the `inline` tool's `send_widget` action or an `<iframe>` block
in its reply; viewer widget calls come back as turns.

Access controls, group mentions, media limits, native message actions, and
additional setup options are described in the
[adapter documentation](https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent#readme).

The catalog pins an exact reviewed source commit. Update a catalog installation
with `hermes plugins update inline-platform` after a new pin is accepted, then
restart the gateway. A newer npm version does not automatically change a
catalog installation.

### Scheduled mentions

To reopen your closed Inline threads when scheduled text arrives, add an opt-in
mention to your Hermes config and restart the gateway:

```yaml
platforms:
  inline:
    cron_mention_prefix: "[@You](inline://user?id=42)"
```

Use your Inline user ID in place of `42`. `INLINE_CRON_MENTION_PREFIX` is the
environment equivalent; an explicit empty YAML value disables it. Markdown
parsing must stay enabled. The prefix applies once to each scheduled gateway
text delivery, respects Hermes' cron notification opt-out, and leaves ordinary
replies alone. Recipient notification settings still apply. Current Hermes
hosts do not identify standalone fallback or media-only sends as cron deliveries,
so those paths cannot add the prefix; scheduled text accompanying media does.

The plugin is distributed under the Apache-2.0 license; see [LICENSE](LICENSE).
