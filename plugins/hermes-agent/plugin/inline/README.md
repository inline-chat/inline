# Inline for Hermes Agent

Use Hermes from Inline work-chat DMs, chats, and reply threads. The plugin
connects Hermes to Inline through a bundled Node.js sidecar; it does not install
npm packages when the gateway starts.

## Requirements

- Hermes Agent 0.18.0 or newer. Automatic gateway restart verification requires
  0.21.0 or newer. With the Inline CLI on 0.18–0.20, use
  `inline agents setup --target hermes --no-restart --non-interactive --json`.
  The result is `configured`, not `ready`; restart through the existing process
  manager and verify an actual final reply in Inline.
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

Access controls, group mentions, media limits, native message actions, and
additional setup options are described in the
[adapter documentation](https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent#readme).

The catalog pins an exact reviewed source commit. Update a catalog installation
with `hermes plugins update inline-platform` after a new pin is accepted, then
restart the gateway. A newer npm version does not automatically change a
catalog installation.

The plugin is distributed under the Apache-2.0 license; see [LICENSE](LICENSE).
