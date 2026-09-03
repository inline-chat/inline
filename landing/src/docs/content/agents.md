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

Support status:

- Codex: alpha.
- Claude Code: experimental.
- OpenCode: experimental.
- Amp: experimental.
- Hermes Agent: experimental.
- OpenClaw: experimental.

## Verify

A ready setup has:

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
