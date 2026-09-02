---
title: "Add Inline to Your Agent"
description: "Add Inline tools to an existing agent."
---

Add Inline's skill and plugin to ChatGPT, Claude, etc. If you want to bring your bot/agent to Inline instead use [Set Up an Agent](/docs/agents).

## Setup Prompt

```text
Install Inline's plugin, skill, and MCP (if CLI is unavailable) based on the guides:
https://inline.chat/docs/add-inline.md
```

## ChatGPT/Codex Plugin

Add the Inline marketplace:

```bash
codex plugin marketplace add inline-chat/inline
```

Install the plugin:

```bash
codex plugin add inline@inline
```

Restart Codex. In ChatGPT desktop, open **Plugins** and install **Inline** from the Inline marketplace.

The plugin includes the Inline skill and MCP integration.

## Skill

If you have the CLI, run:

```bash
inline skill install
```

Or use `npx skills`:

```bash
npx skills add inline-chat/inline --skill inline --global
```

You may need to restart the agent for it to show up.

For manual install, download and copy the folder [`skills/inline` folder](https://github.com/inline-chat/inline/tree/main/skills/inline).

- Codex: `~/.codex/skills/inline`
- Claude Code: `~/.claude/skills/inline`

## MCP

Follow [Connect MCP](/docs/mcp).

## CLI

[Install the CLI](/docs/cli) if you haven't.

Heads up: `inline agents setup` when you only want the plugin, skill, MCP, etc.

## Verify

Ask the agent:

```text
Use Inline to list my chats.
```

---

[Inline plugin](https://github.com/inline-chat/inline/tree/main/plugins/inline) · [Inline skill](https://github.com/inline-chat/inline/tree/main/skills/inline) · [MCP](/docs/mcp) · [CLI](/docs/cli)
