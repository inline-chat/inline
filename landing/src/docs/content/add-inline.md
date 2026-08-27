---
title: "Add Inline to Your Agent"
description: "Install the Inline plugin or skill for ChatGPT, Codex, Claude, and other agents."
---

| Option | Use with | Includes |
| --- | --- | --- |
| Plugin | ChatGPT desktop and Codex | Inline skill and MCP integration |
| Standalone skill | Claude Code and other skill-compatible agents | Workflows for MCP, CLI, and local bridge tools |

## Plugin

Add the Inline marketplace:

```bash
codex plugin marketplace add inline-chat/inline
```

### ChatGPT desktop

Restart ChatGPT, select **ChatGPT Work** or **Codex**, open **Plugins**, then install **Inline** from the Inline marketplace. Start a new chat; Inline requests sign-in when first used.

### Codex

```bash
codex plugin add inline@inline
```

Start a new session. Inline requests sign-in when first used. To install interactively, open `/plugins` after adding the marketplace.

## Standalone Skill

Use the skill without the plugin:

#### Codex

```bash
npx skills add inline-chat/inline --skill inline --global --agent codex --yes
```

#### Claude Code

```bash
npx skills add inline-chat/inline --skill inline --global --agent claude-code --yes
```

#### Other agents

```bash
npx skills add inline-chat/inline --skill inline --global
```

Restart the agent after installation. Connect [MCP](/docs/mcp#connect-an-agent) or sign in through the [CLI](/docs/cli) when the environment does not already provide Inline access.

## Manual Installation

Download the complete [`skills/inline` folder](https://github.com/inline-chat/inline/tree/main/skills/inline), including `references` and `agents`, then copy it to the global skills directory:

| Agent | Destination |
| --- | --- |
| Codex | `~/.codex/skills/inline` |
| Claude Code | `~/.claude/skills/inline` |
| Other agents | Use the skills directory documented by your agent |

Restart the agent, then connect [MCP](/docs/mcp) or authenticate the [CLI](/docs/cli).

## Reference

- [Inline plugin source](https://github.com/inline-chat/inline/tree/main/plugins/inline)
- [Inline skill source](https://github.com/inline-chat/inline/tree/main/skills/inline)
- [`skills` CLI documentation](https://skills.sh/docs/cli)
- [Inline MCP setup](/docs/mcp)
