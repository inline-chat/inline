---
title: "Agents"
description: "Set up an agent as an Inline bot with the CLI, bridge, gateway, or integration plugins it needs."
---

Connect an agent running on your computer to an Inline bot. Send it work from Inline on your phone or desktop and receive its replies in the same chat. Setup installs the Inline CLI and any bridge, gateway, or integration plugins needed for that connection.

## Setup Prompt

Copy this request to the agent you want to connect:

```text
Set up this agent as a bot in Inline by following https://inline.chat/docs/agents.md
```

## Instructions for Agents

Use the existing agent runtime and let the Inline CLI create or reuse the bot, install the required integration, and start its bridge or gateway. Keep the agent's existing instructions and model/provider configuration.

### 1. Prepare the Inline CLI

Check whether the CLI is installed:

```bash
inline --version
```

If it is missing, install it on macOS or Linux:

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

If `inline agents setup --help` is unavailable, [update the CLI](/docs/cli#update-and-troubleshoot). Reuse the existing Inline sign-in; check it with `inline me`. If sign-in is needed, run the following and give the user the sign-in URL:

```bash
inline login --browser --no-open
```

Let the user complete sign-in. Do not ask them to paste tokens or read credential files.

### 2. Connect the Current Agent

Choose the runtime the user is addressing: Codex → `codex`, Claude Code → `claude`, OpenCode → `opencode`, Amp → `amp`, Hermes → `hermes`, or OpenClaw → `openclaw`. Do not choose Codex just because it is the example or install a different runtime. If the current runtime is unclear or unsupported, ask which installed agent to connect.

Check which targets are installed without changing state:

```bash
inline agents discover --json --compact
```

For Codex, run this command; replace `codex` with the selected target for another runtime:

```bash
inline agents setup --target codex --non-interactive --json
```

For a local coding agent scoped to a project, also pass `--folder /absolute/path/to/project`. Without it, local targets default to the home directory. Keep the default owner-only access unless the user explicitly requests otherwise. Setup creates or reuses the bot and starts the bridge or gateway; do not stop after installing the CLI or signing in.

### 3. Hand Off the Bot and Verify a Reply

Check the result's `status` and `service.ready`. If it reports `configured`, `partial`, or an error, follow [Recovery](#recovery); do not report the connection as ready. Do not use `--replace` without the user's approval.

When `status` is `ready` and `service.ready` is `true`, give the user the returned `openUrl` and bot username. Ask them to send the [verification prompt](#verify-a-conversation) in that bot's Inline chat. Setup is verified only after a final reply arrives there. If you cannot observe the reply, report “connected; conversation verification pending.”

## Local Coding Agents

> **One-click setup on macOS**
> Choose **Set Up an Agent…** from the app menu, or open **Settings → Bots → Set Up Agent…**. The wizard installs or updates the trusted CLI, signs in, detects local agents, creates or reuses the bot, installs the integration, and verifies it.

Terminal setup:

```bash
inline agents setup
```

Agents and scripts should use the [non-interactive flow above](#instructions-for-agents).

Supported targets: Codex, Claude, OpenCode, Amp, Hermes, and OpenClaw. Install and sign in to your chosen runtime first. Inline installs its adapter or plugin, not the third-party runtime. The computer running the bridge or gateway must remain available to receive work.

Local targets default to the home directory unless `--folder` selects a narrower workspace. Select a project directory deliberately; chat access does not expand the provider's local permissions.

```bash
inline agents setup --target codex --folder /path/to/project
```

Compatibility commands: `inline setup codex|opencode|claude|amp`. Gateway shortcuts: `inline setup hermes|openclaw`. Codex is the primary local-bridge beta path; Claude, OpenCode, and Amp are experimental.

Local bridge status:

```bash
inline bridge status
```

Gateway status:

```bash
hermes inline status --json --probe
```

```bash
openclaw channels status --channel inline --probe --json
```

### Verify a Conversation

Open the bot in Inline and send a small prompt, such as “Reply with hello; do not run commands or change files.” Confirm a final reply appears in the intended chat. A healthy process or successful setup result alone does not prove an agent can complete a turn.

If you cannot find **Set Up an Agent…**, update Inline or use the terminal setup above. In a shared thread, use an explicit bot mention and check the integration's operator policy before sending work.

### Recovery

The app and JSON output report the failed phase, stable error code, retry command, documentation link, and confirmed changes. Setup is safe to retry. Conflicting Hermes or OpenClaw configurations require confirmation before `--replace`.

| Error | What to do |
| --- | --- |
| `not_authenticated` | Sign in with `inline login`, then retry. |
| `target_not_installed` | Install the selected harness, or choose another detected harness. |
| `setup_conflict` / `mapped_bot_missing` | Retry from the app with **Repair Existing Setup**, or rerun the command with `--replace`. |
| `plugin_unavailable` | Allow Inline to install the integration, or install/update it manually. |
| `agent_setup_failed` | Run the provided retry command in Terminal; diagnostics do not print the token. |

An outdated Homebrew CLI is preserved; the wizard installs a compatible signed copy elsewhere. If a runtime installed through Volta, nvm/fnm, asdf/mise, pnpm, or Bun is missing, run `inline agents discover --json --compact` in Terminal.

`status: "partial"` means some listed changes completed. Retry normally; setup reconciles Inline-owned state instead of creating another bot.

## Setup Paths

| Path | Use |
| --- | --- |
| [Local agent](#local-coding-agents) | Run Codex, Claude, OpenCode, or Amp on your Mac from Inline chats |
| [OpenClaw](/docs/openclaw) | Add Inline as an OpenClaw channel |
| [Hermes](/docs/hermes) | Run Hermes from Inline chats and reply threads |

## Agent Workflows

For workspace routing, operator permissions, and local process ownership, see [Local Agents](/docs/technical/local-agents).
