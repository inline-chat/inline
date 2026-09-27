---
title: "Hermes Agent"
description: "Connect an existing Hermes Agent to Inline, locally or on an Umbrel server."
---

## Before you begin

Use Hermes Agent `>=0.21.3`, Node.js `>=20`, npm, and the
[Inline CLI](/docs/cli). Hermes `0.21.3`, shipped in the official Umbrel app,
requires adapter `0.0.20` or later.
Run setup as the user and in the container that already runs Hermes, with the
same `HERMES_HOME` and profile. Setup adds an Inline channel to that agent;
it does not migrate or replace its models, memory, skills, or other channels.

## Supported versions

| Hermes version | Latest supported Inline adapter |
| --- | --- |
| `0.21.3` (Umbrel app `2026.9.14`) | `0.0.20` |
| `0.21.4` | `0.0.20` |
| `0.21.5` | `0.0.20` |

Earlier Hermes versions are not covered by this release. Compatibility work for
those versions is separate; use the matching supported host and adapter above.

## Agent setup prompt

Give your coding agent SSH access to the server and this prompt:

```text
Connect my existing Hermes on my Umbrel server to Inline using
https://inline.chat/docs/hermes.md.
Find the existing Hermes container, service user, persisted Hermes home and
profile first. Preserve its models, memory, skills and existing channels.
Install the Inline CLI and adapter in persistent storage as that service user.
Use browser sign-in with --no-open and give me the approval URL when needed.
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

Open the printed URL on your own computer and approve the login. This signs
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

Run in the same user, home, profile, and persistent npm prefix used at install:

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

## Source

- [Adapter source and reference](https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent)
- [CLI Hermes setup](https://github.com/inline-chat/inline/blob/main/cli/src/agents/hermes.rs)
