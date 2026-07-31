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

Install and sign in to the [Inline CLI](/docs/cli), then connect a project folder. Setup is persistent; you do not start a new bridge for every chat.

### Codex

```bash
inline setup codex --folder /path/to/project
```

### OpenCode

```bash
inline setup opencode --folder /path/to/project
```

### Claude

```bash
inline setup claude --folder /path/to/project
```

### Amp

```bash
inline setup amp --folder /path/to/project
```

Codex is the primary beta path. OpenCode, Claude, and Amp are experimental;
check the compatibility details below before relying on them for daily work.

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
