---
title: "Hermes Agent"
description: "Connect an existing Hermes Agent to Inline, locally or on an Umbrel server."
---

## Before you begin

Use Hermes Agent `>=0.21.3`, Node.js `>=20`, npm, and the
[Inline CLI](/docs/cli). Hermes `0.21.3`, shipped in the official Umbrel app,
requires adapter `0.0.20` or later. Running several Hermes profiles in one
gateway (the default since Hermes `0.22.0`) requires adapter `1.0.0`.
Run setup as the user and in the container that already runs Hermes, with the
same `HERMES_HOME` and profile. Setup adds an Inline channel to that agent;
it does not migrate or replace its models, memory, skills, or other channels.

## Supported versions

| Hermes version | Adapter `0.0.x` | Adapter `1.0.0` |
| --- | --- | --- |
| `0.21.3` (Umbrel app `2026.9.14`) – `0.21.5` | Supported from `0.0.20` | Supported |
| `0.22.0` and later, one profile | Supported | Supported |
| `0.22.0` and later, several profiles in one gateway | Not supported: every profile connects as the launch profile's bot and shares its state | Supported |

Hermes `0.22.0` runs every profile in one gateway process by default. Adapter
`1.0.0` reads each profile's Inline settings and token from that profile, keeps
one state file per profile and bot, and refuses to connect a bot another
gateway is already using. On Hermes `0.21.x` it reads them from the gateway's
environment, as before.

Hermes `/branch` stays in the current Inline thread: Hermes opens branch
threads only on its built-in platforms.

Earlier Hermes versions are not covered. Compatibility work for those versions
is separate; use a supported host and adapter above.

## Upgrading to 1.0

Adapter `1.0.0` changes how the bot decides a message is for it and how it
answers. Review these before upgrading:

- **Only Inline addressing wakes the bot.** Words such as its name no longer
  do, and `INLINE_MENTION_PATTERNS` is removed. Mentions, replies to the bot,
  commands for it, direct messages and threads it follows still work.
- **A message that starts by mentioning someone else isn't for the bot**, even
  if it mentions the bot later, replies to it, or sits in a thread it follows.
- **Replies to other people or bots don't wake it** unless they mention it.
  Replying to your own earlier message still continues the conversation.
- **Unfollow wins in free-response chats.** Mentions and replies still reach
  the bot.
- **Bots enter a thread through its first message.** A thread follows the bots
  its first message mentions. A thread only you and one bot can see, or one
  under a bot's direct message, follows that bot. A bot mentioned later answers
  once without following, and a command runs once without assigning anyone,
  nor does a bot's answer to it: the first message that isn't a command
  decides. The agent can follow or
  unfollow a thread itself.
- **Answers quote the request only when answering another bot**, so that bot
  sees the answer. Set `INLINE_REPLY_TO_MODE=first` to quote every answer.
- **Commands go to the bot they name.** Picking a command from Inline's
  suggestions names its bot. A command several bots offer, typed without a
  name, goes to the bot you replied to or the one bot following the thread;
  otherwise no bot runs it.
- **A thread's first message and its follow-ups share one conversation.** The
  first message used to start a separate session from the replies inside the
  thread.
- **The agent can manage chats.** It can add people or agents, rename a chat
  and delete one it created. A private chat it creates for you includes you.
- **Status tells you whether messages are arriving.** `hermes inline status`
  and `inline-hermes doctor` now report "Receiving Inline messages" separately
  from "ready" (installed and configured), with the next step when the gateway
  isn't running or Inline isn't connected.
- **The bot shows Working instead of typing** while it works. Older Inline apps
  show typing.
- **State moves into each profile.** The SDK state file is now
  `$HERMES_HOME/inline/sdk-state-bot<id>-<server>.json`, one per bot. The default
  profile reuses the old `~/.hermes/inline/sdk-state.json` once; other profiles
  start from the upgrade, so messages sent while the gateway restarts may not
  be picked up.
- **The sidecar takes a free local port** unless `INLINE_SIDECAR_PORT` is set.
- **Reply threads are Auto or On, per chat.** Auto (the default) answers in the
  chat and starts a thread only when someone asks for one; words alone never
  start one. On answers each message in a reply thread, in a DM or a group, and
  is set per chat with `/threads on`, the agent settings, or by asking the
  agent. Off is gone, and `INLINE_REPLY_THREADS=on` as a bot-wide default now
  reads as Auto, so a new tab's first message never gets a thread. When the
  agent opens a thread for your message, its answer goes there, and asking
  again returns the same thread.
- **A thread under the bot's DM stays your DM.** You don't need to mention the
  bot there, and the thread's first answer and your replies share one
  conversation. Anyone else added to it is treated like any thread member.

## Agent setup prompt

Give your coding agent SSH access to the server and this prompt:

```text
Connect my existing Hermes on my Umbrel server to Inline using
https://inline.chat/docs/hermes.md.
Find the existing Hermes container, service user, persisted Hermes home and
profile first. Preserve its models, memory, skills and existing channels.
Install the Inline CLI and adapter in persistent storage as that service user.
Use browser sign-in with --no-open and give me the approval URL and code when needed.
Do not read or print .env files, tokens, or other secrets. Do not create a
second Hermes instance or replace an existing Inline bot without asking.
Finish by verifying the live gateway and an actual reply in Inline.
```

## Existing Hermes on Umbrel

SSH to the Umbrel host. Discover the running Hermes container without dumping
its environment or configuration:

```bash
sudo docker ps --format '{{.Names}}\t{{.Image}}'
```

The official Hermes app currently uses the `hermes` service user and persisted
`HERMES_HOME=/opt/data`. Enter the existing container (replace `CONTAINER` with
the name returned above; it is commonly `hermes-agent_web_1`):

```bash
sudo docker exec -it --user hermes -e HOME=/opt/data/home CONTAINER bash
```

Inside that container, verify the runtime and install into its persistent volume:

```bash
export HERMES_HOME=/opt/data
export PATH="/opt/data/.local/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"
export npm_config_prefix=/opt/data/.local
hermes --version
node --version
npm --version
curl -fsSL https://inline.chat/cli/install.sh | INLINE_INSTALL_DIR=/opt/data/.local/bin sh
inline --version
```

Use these paths only for the official app layout. For a custom image, identify
its actual service user and durable Hermes home first. Do not install into the
Umbrel host's home or create a new profile. `inline agents discover` inspects
only the environment where it runs; it does not discover Hermes across SSH or
Docker boundaries. An interactive `docker exec` shell may omit Hermes from
PATH even when the gateway runs normally. Keep `/opt/hermes/bin` before
`/opt/hermes/.venv/bin` so gateway commands use the app's supervisor wrapper.
Guided setup uses npm's cache under the persistent `HOME`;
`npm_config_prefix` selects the persistent location for the manual global
install/update commands below. It does not need to remain in the gateway
environment. Persistent files survive container replacement. For custom
images, retain any custom PATH or Node settings in the app's supported
startup configuration.

## Connect Inline

Run these commands in the same environment as Hermes:

```bash
inline me --json
```

If sign-in is required:

```bash
inline login --browser --no-open
```

Open the printed URL on your own computer, sign in, and enter the printed
6-digit code to approve the login. This signs
in the CLI as the bot owner; setup then configures a separate bot credential
without printing it.

Preview and configure:

```bash
inline agents setup --target hermes --dry-run --non-interactive --json
inline agents setup --target hermes --non-interactive --json
```

For a named existing profile, add `--profile NAME` to both commands. To reuse
an existing bot, add `--bot-id ID`. Setup defaults to `--access owner`; use
`--access allowlist --allow-user ID` for additional operators. Do not use `--replace` unless you
intend to replace a conflicting Inline credential.

Setup installs the adapter, enables the plugin, configures Inline, and asks
Hermes to restart its gateway. Current official Umbrel images route Hermes'
gateway commands through their s6 supervisor; they do not need a systemd
service inside the container. If the installed host cannot manage its gateway,
use `--no-restart`, then restart it through that deployment's existing process
manager. A configured result is not a ready gateway.

## Resume an incomplete setup

If a previous attempt already created a bot, sign in as its owner in this
same container with `inline login --browser --no-open`, then list your bots:

```bash
inline bots list --json
```

Find the intended bot's ID and reuse it instead of creating another:

```bash
inline agents setup --target hermes --bot-id BOT_ID --dry-run --non-interactive --json
inline agents setup --target hermes --bot-id BOT_ID --non-interactive --json
```

Replace `BOT_ID` with the returned numeric ID. Add `--profile NAME` when
using a named existing profile. A signed-out CLI and a disabled Hermes plugin
are separate states: signing in restores the owner's CLI session, while setup
enables and configures the plugin. Do not reset the Hermes home or replace a
conflicting bot credential to recover a partial setup. If setup reports a
conflict, confirm the intended bot before using `--replace`.

## Install from the Hermes Catalog

You can also install Inline from the [Hermes plugin catalog](https://hermes-agent.nousresearch.com/docs/plugins/inline-platform):

```bash
hermes plugins install inline-platform
```

In the same Hermes home and profile, enable the plugin and configure the gateway:

```bash
hermes plugins enable inline-platform
hermes gateway setup
```

Select **Inline** and configure its bot credential. Restart through your existing
process manager, then check `hermes inline status --json --probe` and verify a
reply in Inline.

## Verify

The guided setup uses `npm exec`; it does not require a global `inline-hermes`
command. Run the doctor through the package too:

```bash
npm exec --yes --package=@inline-chat/hermes-agent-adapter -- inline-hermes doctor --json
hermes inline status --json --probe
hermes gateway status
```

Use the same profile and home for these checks. Setup reports `status: "ready"`
and `service.ready: true` only after checking the credential and gateway.
Inspect the nested gateway readiness in a standalone status probe as well;
a valid credential alone does not prove that the gateway is running.

Find the bot using the returned `openUrl` or username in Inline search, send a
message, and verify a final reply. This last check also exercises your existing
Hermes model/provider credentials and inbound delivery.

## Manual installation

If you already manage bot credentials and gateway configuration:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install
hermes plugins enable inline-platform
hermes gateway setup
```

Select **Inline**, then use the guided setup or an existing [bot token](/docs/creating-a-bot).
The wizard saves configuration first. Restart through your process manager and
complete the checks above before declaring it ready.

## Update

For a catalog installation:

```bash
hermes plugins update inline-platform
hermes gateway restart
```

For an npm installation, run in the same user, home, profile, and persistent npm prefix used at install:

```bash
inline update
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
hermes gateway restart
inline-hermes doctor --json
hermes inline status --json --probe
```

Adapter `0.0.19` no longer provides `/inline_update`; update through the package
manager. `install --force` refreshes plugin files while preserving Hermes
configuration and credentials.

## Shared transcripts in groups and threads

To share one conversation transcript among admitted participants in a group
or thread, add these keys at the root of the `config.yaml` used by the Hermes
gateway process, outside `platforms.inline.extra`:

```yaml
group_sessions_per_user: false
thread_sessions_per_user: false
```

Hermes defaults `group_sessions_per_user` to `true` (groups split by sender)
and `thread_sessions_per_user` to `false` (threads shared). These settings
affect every messaging platform governed by that gateway configuration.
For separate profile gateways, configure each gateway's profile separately.
With a multiplexed gateway, do not assume a secondary profile's values control
its sessions; this adapter does not qualify per-profile session-policy overrides.

Distinct Hermes profile/gateway namespaces keep separate conversation sessions.
Swapping a bot token within one profile does not create a new transcript namespace.
These flags select shared sessions; they do not merge existing histories, import
all Inline history, grant permissions, or change access, mention, or bot wake rules.
Restart the gateway through its existing process manager after editing.

## Source

- [Adapter source and reference](https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent)
- [CLI Hermes setup](https://github.com/inline-chat/inline/blob/main/cli/src/agents/hermes.rs)
