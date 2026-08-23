# Agents

Source: https://inline.chat/docs/agents

Connect an agent to Inline as a private local bot, through MCP, or with an agent platform integration.

## Choose a setup

- **[Add Inline to your agent](https://inline.chat/docs/add-inline)**

  Install the Inline plugin or skill for ChatGPT, Codex, Claude, and other agents.
- **[Local coding agents](#local-coding-agents)**

  Run Codex, Claude, OpenCode, or Amp on your Mac and talk to it from Inline.
- **[Inline MCP](https://inline.chat/docs/mcp)**

  Give an MCP client access to approved Inline spaces with OAuth consent.
- **[OpenClaw](https://inline.chat/docs/openclaw)**

  Add Inline as an OpenClaw channel.
- **[Hermes Agent](https://inline.chat/docs/hermes)**

  Run Hermes from Inline chats and reply threads.

## Local coding agents

On macOS, choose **Set Up an Agent…** from Inline's app menu or the Bots settings page. The wizard installs or updates the trusted Inline CLI, signs it in, finds every supported harness already installed on your Mac, and lets you choose which one to connect.

You can run the same unified flow in Terminal:

```bash
# Detect installed harnesses and choose interactively
inline agents setup

# Prompt-free setup for an agent or script
inline agents setup --target codex --non-interactive --json
inline agents setup --target hermes --non-interactive --json
inline agents setup --target openclaw --non-interactive --json

# Equivalent gateway shortcuts
inline setup hermes --non-interactive --json
inline setup openclaw --non-interactive --json
```

Supported harnesses are Codex, Claude, OpenCode, Amp, Hermes, and OpenClaw. Inline installs its own adapter or plugin, but it does not silently install those third-party runtimes. If a local coding harness needs no explicit folder, Inline uses your home directory; pass `--folder` to use a narrower workspace.

```bash
inline agents setup --target codex --folder /path/to/project
```

Read-only discovery is available for troubleshooting and app integrations:

```bash
inline agents discover --json --compact
```

The older `inline setup codex|opencode|claude|amp` commands remain supported. Codex is the primary local-bridge beta path; OpenCode, Claude, and Amp are experimental, while Hermes and OpenClaw use their own gateway integrations.

Check Codex, Claude, OpenCode, and Amp bridge health with:

```bash
inline bridge status
```

Hermes and OpenClaw run as gateways and have separate health checks:

```bash
hermes inline status --json --probe
openclaw channels status --channel inline --probe --json
```

### If setup cannot finish

After target setup begins, the app and `--json` output identify the failed phase, stable error code, retry command, documentation link, and any work completed before the failure. Earlier validation and authentication failures provide a stable code and message; the app adds guide and retry recovery where possible. Setup is safe to retry. Inline asks before using `--replace` to repair a conflicting Hermes or OpenClaw configuration.

| Error | What to do |
| --- | --- |
| `not_authenticated` | Sign in with `inline login`, then retry. |
| `target_not_installed` | Install the selected harness, or choose another detected harness. |
| `setup_conflict` / `mapped_bot_missing` | Retry from the app with **Repair Existing Setup**, or rerun the command with `--replace`. |
| `plugin_unavailable` | Allow Inline to install the integration, or install/update it manually. |
| `agent_setup_failed` | Run the provided retry command in Terminal for bounded diagnostics; no token is printed. |

If the app finds an outdated Homebrew CLI, the wizard installs a compatible signed copy in another safe location without overwriting the Homebrew file. The standalone CLI menu continues to respect Homebrew ownership. If a harness installed through Volta, nvm/fnm, asdf/mise, pnpm, Bun, or a similar version manager is still missing, run `inline agents discover --json --compact` in Terminal and use the setup command there.

If a run reports `status: "partial"`, it may have changed local or Inline-owned state; its `changes` array lists only work the CLI can confirm completed. Retry normally—the setup flow reconciles existing Inline-owned state instead of creating another bot.

For provider requirements, security boundaries, and current compatibility details, see the [local agent bridge source](https://github.com/inline-chat/inline/blob/main/docs/local-agent-bridge.md).

## Agent workflows

Install the official Inline skill after the CLI is ready:

```bash
inline skill install
```

The skill adds focused workflows for Inline MCP, the CLI, and local agents. See [Add Inline to your agent](https://inline.chat/docs/add-inline) for plugin, `npx skills`, and manual setup.
