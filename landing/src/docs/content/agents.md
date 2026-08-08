# Agents

Connect an agent to Inline as a private local bot, through MCP, or with an agent platform integration.

## Choose a setup

- **[Add Inline to your agent](/docs/add-inline)**

  Install the Inline plugin or skill for ChatGPT, Codex, Claude, and other agents.
- **[Local coding agents](#local-coding-agents)**

  Run Codex, Claude, OpenCode, or Amp on your Mac and talk to it from Inline.
- **[Inline MCP](/docs/mcp)**

  Give an MCP client access to approved Inline spaces with OAuth consent.
- **[OpenClaw](/docs/openclaw)**

  Add Inline as an OpenClaw channel.
- **[Hermes Agent](/docs/hermes)**

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

Check all configured agents with one command:

```bash
inline bridge status
```

For provider requirements, security boundaries, and current compatibility details, see the [local agent bridge source](https://github.com/inline-chat/inline/blob/main/docs/local-agent-bridge.md).

## Agent workflows

Install the official Inline skill after the CLI is ready:

```bash
inline skill install
```

The skill adds focused workflows for Inline MCP, the CLI, and local agents. See [Add Inline to your agent](/docs/add-inline) for plugin, `npx skills`, and manual setup.
