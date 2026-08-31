---
title: "Add Inline to Your Agent"
description: "Add Inline MCP, CLI, skills, and plugin access to your existing agent."
---

Give your existing agent tools to read, search, and send messages in Inline. This guide covers MCP, the CLI, skills, and the Inline plugin. It does not create a bot or connect a local agent bridge. To message the agent from Inline, use [Agent Setup](/docs/agents).

## Setup Prompt

Copy this request to the agent that should use Inline:

```text
Add Inline to this agent by following https://inline.chat/docs/add-inline.md
```

## Choose Integrations

Reuse integrations that already work. Choose the options supported by the current agent; a plugin that includes the skill and MCP connection does not need a duplicate standalone installation. The CLI also provides access for shell workflows. Do not install a different agent runtime.

| Option | Use with | Includes |
| --- | --- | --- |
| [Plugin](#plugin) | ChatGPT desktop and Codex | Inline skill and MCP integration |
| [Standalone skill](#standalone-skill) | Claude Code and other skill-compatible agents | Inline workflows; authenticate through MCP or the CLI |
| [MCP](#mcp) | MCP-compatible agents | Hosted tools with scoped OAuth access |
| [CLI](#cli) | Agents with shell access | Command-line tools using the signed-in Inline account |

Complete sign-in through the selected integration. Do not ask the user to paste tokens or read credential files. Installing instructions alone does not grant account access; finish with [Verify](#verify).

## Plugin

Add the Inline marketplace:

```bash
codex plugin marketplace add inline-chat/inline
```

### ChatGPT desktop

Restart ChatGPT, select **ChatGPT Work** or **Codex**, open **Plugins**, then install **Inline** from the Inline marketplace. Start a new chat; Inline requests sign-in when first used.

These steps require a desktop version with plugin support. If the marketplace is missing, check [OpenAI's marketplace setup guidance](https://developers.openai.com/plugins/build/plugins), or connect [Inline MCP](/docs/mcp) in a supported client.

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

## MCP

Use the [MCP setup guide](/docs/mcp#connect-an-agent) to connect the hosted server and complete OAuth consent. If the Inline plugin already provides MCP, use that connection. Grant only the spaces and conversation types the user wants the agent to access.

## CLI

Check for an existing installation:

```bash
inline --version
```

If needed, [install the CLI](/docs/cli#install). Reuse an existing sign-in or run:

```bash
inline login --browser --no-open
```

Give the user the sign-in URL and let them complete authentication. Then check the account:

```bash
inline me
```

For Codex, the CLI can install the Inline skill if it is not already present:

```bash
inline skill install
```

For other agents, use the [standalone skill instructions](#standalone-skill). Restart the agent after installing the skill. See the [CLI guide](/docs/cli) for chat, search, and message commands; do not run `inline agents setup` for tool access.

## Manual Installation

Download the complete [`skills/inline` folder](https://github.com/inline-chat/inline/tree/main/skills/inline), including `references` and `agents`, then copy it to the global skills directory:

| Agent | Destination |
| --- | --- |
| Codex | `~/.codex/skills/inline` |
| Claude Code | `~/.claude/skills/inline` |
| Other agents | Use the skills directory documented by your agent |

Restart the agent, then connect [MCP](/docs/mcp) or authenticate the [CLI](/docs/cli).

## Verify

Ask the agent to list the Inline conversations it is allowed to read, without sending or changing anything. Complete sign-in if prompted, then confirm the returned context is yours. If no Inline tools are available, start a new session and check that the plugin is enabled or the skill is installed for that agent.

The skill provides instructions; access comes from MCP consent or the CLI account. It does not create a responding bot inside Inline. For that, use [agent setup](/docs/agents).

## Reference

- [Inline plugin source](https://github.com/inline-chat/inline/tree/main/plugins/inline)
- [Inline skill source](https://github.com/inline-chat/inline/tree/main/skills/inline)
- [`skills` CLI documentation](https://skills.sh/docs/cli)
- [Inline MCP setup](/docs/mcp)
