---
title: "Set Up an Agent"
description: "Connect an agent to an Inline bot."
---

## Setup Prompt

Paste this into your favorite LLM so it can do the setup itself.

```text
Set up this agent as a bot in Inline:
https://inline.chat/docs/agents.md
```

Ideally specify which of your agents you want to bring and whether it's local or remote. For example:

```text
Set up my local OpenClaw as a bot in Inline:
https://inline.chat/docs/agents.md
```

## Inline for Mac

If you have the macOS app, we have a wizard for setting up your local agents. It sets up the CLI, finds your harnesses, installs the plugins, configures them, creates a bot, authenticates the plugin, and opens the chat ready to use. It may be brittle given the number of moving parts, so if it fails, try those steps manually.
Open **Inline → Settings → Bots → Set Up Agent…** or choose **Set Up an Agent…** from the app menu.

## Before you start

Install the agent on the machine that will run it, and sign in to it there:

- Codex: 0.146 or newer. Run `codex login`.
- Claude Code: 2.0.32 or newer. Run `claude`, then `/login`. CLI 0.7.19 and
  earlier also need Node.js 22 or newer and npm.
- Hermes and OpenClaw: follow their guides below.

Inline does not install these for you. Setup checks them and tells you what is
missing.

The agent works in your home folder unless you pass `--folder /path/to/project`
to `inline agents setup`.

## Using the CLI

Check the CLI:

```bash
inline --version
```

[Install](/docs/cli) it if missing:

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Sign in if needed:

```bash
inline login --browser --no-open
```

This prints a URL and a 6-digit code. Open the URL, sign in, and enter the code
in the browser. Keep the command running until it finishes.

For an existing remote Hermes, follow [Hermes on Umbrel or a server](/docs/hermes)
first. Run the CLI in the same container, service user, and profile as the
existing agent. Discovery does not search remote machines or other containers.

Find installed agents:

```bash
inline agents discover
```

Run interactive setup:

```bash
inline agents setup
```

Agents and scripts should select the current runtime explicitly:

```bash
inline agents setup --target codex
```

Targets are `codex`, `claude` (Claude Code), `opencode`, `amp`, `hermes`, and
`openclaw`.

Support status:

- Codex: stable.
- Claude Code: beta.
- OpenCode: beta.
- Amp: experimental.
- Hermes Agent: beta.
- OpenClaw: experimental.

## Native Codex and Claude bridge

Codex and Claude Code run on the native bridge (v2). Each thread has one native
session per agent, with work state, settings, approval and question
interactions, and controls. OpenCode and Amp keep using the previous bridge.

Upgrading from an earlier CLI needs no setup. Existing conversations continue
in their Codex or Claude session, or start a fresh one when that session is no
longer on the machine. For a bridge installed before the new updater, wait until
your agents are idle before the first upgrade, then run `inline bridge restart`
once using the newly installed executable.

Once enrolled, managed updates wait for active work to finish. Automatic runtime
activations are spaced at least six hours apart, so the terminal and background
bridge can temporarily report different versions. Homebrew-owned CLI executables
stay managed by Homebrew; the enrolled background bridge can update independently.
Check the installed binary and provider paths with `inline bridge doctor --json`.
If another CLI installation shadows it on PATH, use the updated executable’s
full path for these commands.

To roll back, set `INLINE_BRIDGE_V2=off` in the **bridge service's environment**
and restart it; a variable set only in your terminal does not reach an existing
background service.

## Verify

Setup prints `{name} is ready in Inline.` with the bot's username. With `--json`,
a ready setup has:

- `status: "ready"`
- `service.ready: true`
- A bot username and `openUrl`

Open the bot via CMD+K or search on iOS and start chatting.

## Status

Check a local bridge (for Codex/Claude/OpenCode/Amp setups that use our bridge):

```bash
inline bridge status
```

Check Hermes:

```bash
hermes inline status --json --probe
```

Check OpenClaw:

```bash
openclaw channels status --channel inline --probe --json
```

---

[OpenClaw](/docs/openclaw) · [Hermes Agent](/docs/hermes) · [Local-agent boundaries (Technical)](/docs/technical/local-agents)

## Source

- [CLI agent discovery and setup](https://github.com/inline-chat/inline/tree/main/cli/src/agents)
- [Coding-agent bridge reference](https://github.com/inline-chat/inline/blob/main/cli/docs/local-agent-bridge.md)
