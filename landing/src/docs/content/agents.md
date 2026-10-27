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

Support status:

- Codex: alpha.
- Claude Code: beta.
- OpenCode: beta.
- Amp: experimental.
- Hermes Agent: beta.
- OpenClaw: experimental.

## Bridge v2 alpha

[CLI `0.7.19-alpha.3`](https://github.com/inline-chat/inline/releases/tag/cli-v0.7.19-alpha.3)
includes the native Codex and Claude bridge. Download the archive for your
platform from that prerelease and verify its published checksum. The normal
installer, updater, and Homebrew remain on the stable release.

Bridge v2 is opt-in with `INLINE_BRIDGE_V2=codex,claude` in the **bridge service's
environment**. A variable set only in your terminal does not reach an existing
background service. For macOS, set that entry in the account's LaunchAgent
`EnvironmentVariables` dictionary, then reload the LaunchAgent at an idle
boundary. For Linux, use the corresponding systemd user service environment
override and restart it. Check the installed binary and provider paths with
`inline bridge doctor --json`. Regenerating the service definition can remove a
manual environment override; verify the setting after setup or restart.

Each thread has one native session per agent, with work state, settings,
approval/question interactions, and controls. OpenCode and Amp keep using v1.
Some iOS interaction presentation and native session browsing are still in
progress. Test in a controlled conversation and retain the existing bridge
state and previous binary for recovery.

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

## Source

- [CLI agent discovery and setup](https://github.com/inline-chat/inline/tree/main/cli/src/agents)
- [Coding-agent bridge reference](https://github.com/inline-chat/inline/blob/main/cli/docs/local-agent-bridge.md)
