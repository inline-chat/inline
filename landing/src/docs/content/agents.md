---
title: "Agents"
description: "Connect coding agents and agent platforms to Inline."
---

## Setup Paths

| Path | Use |
| --- | --- |
| [Plugin or skill](/docs/add-inline) | Add Inline tools to ChatGPT, Codex, Claude, or another agent |
| [Local agent](#local-coding-agents) | Run Codex, Claude, OpenCode, or Amp on your Mac from Inline chats |
| [MCP](/docs/mcp) | Grant an MCP client access to approved Inline context through OAuth |
| [OpenClaw](/docs/openclaw) | Add Inline as an OpenClaw channel |
| [Hermes](/docs/hermes) | Run Hermes from Inline chats and reply threads |

## Local Coding Agents

> **One-click setup on macOS**
> Choose **Set Up an Agent…** from the app menu, or open **Settings → Bots → Set Up Agent…**. The wizard installs or updates the trusted CLI, signs in, detects local agents, creates or reuses the bot, installs the integration, and verifies it.

Terminal setup:

```bash
inline agents setup
```

Non-interactive setup:

```bash
inline agents setup --target codex --non-interactive --json
```

Supported targets: Codex, Claude, OpenCode, Amp, Hermes, and OpenClaw. Inline installs its adapter or plugin, not the third-party runtime. Local targets default to the home directory unless `--folder` selects a narrower workspace.

```bash
inline agents setup --target codex --folder /path/to/project
```

Detect installed targets without changing state:

```bash
inline agents discover --json --compact
```

Compatibility commands: `inline setup codex|opencode|claude|amp`. Gateway shortcuts: `inline setup hermes|openclaw`. Codex is the primary local-bridge beta path; Claude, OpenCode, and Amp are experimental.

Local bridge status:

```bash
inline bridge status
```

Gateway status:

```bash
hermes inline status --json --probe
openclaw channels status --channel inline --probe --json
```

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

[Local agent process and security boundaries](/docs/technical/local-agents)

## Agent Workflows

```bash
inline skill install
```

For plugin, `npx skills`, and manual installation, see [Add Inline to Your Agent](/docs/add-inline).
