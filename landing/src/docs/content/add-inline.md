# Add Inline to Your Agent

Use the Inline plugin for ChatGPT desktop and Codex, or install the standalone Inline skill in Claude Code and other agents.

> The plugin includes Inline MCP and the skill. The standalone skill can use [Inline MCP](/docs/mcp), the authenticated [Inline CLI](/docs/cli), or local bridge tools. Neither MCP nor the CLI is universally preferred; the right path depends on the host—such as ChatGPT on iOS or macOS versus Codex with shell access—and the access already available.

## ChatGPT desktop

Until Inline appears in the public Plugins Directory, add the Inline marketplace from a terminal:

```bash
codex plugin marketplace add inline-chat/inline
```

Restart the ChatGPT desktop app, select **ChatGPT Work** or **Codex**, and open **Plugins**. Choose the **Inline** marketplace and install **Inline**.

Start a new chat after installation. Inline will ask you to sign in when it first needs access.

## Codex

Add the public Inline marketplace:

```bash
codex plugin marketplace add inline-chat/inline
```

Install the plugin:

```bash
codex plugin add inline@inline
```

Start a new Codex session. The Inline skill and MCP tools will be available, and Codex will prompt you to sign in when needed.

You can also open `/plugins` after adding the marketplace and install Inline interactively.

## Install the standalone skill

Use the standalone skill when you do not want the full plugin or your agent does not support it.

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

Restart the agent so it discovers the skill. It can use MCP, an authenticated Inline CLI, or local bridge tools depending on what the environment provides. See [MCP setup](/docs/mcp#connect-an-agent) and [CLI setup](/docs/cli).

## Manual installation

Download the complete [`skills/inline` folder from GitHub](https://github.com/inline-chat/inline/tree/main/skills/inline), including its `references` and `agents` folders. Copy it to your agent's global skills directory:

| Agent | Destination |
| --- | --- |
| Codex | `~/.codex/skills/inline` |
| Claude Code | `~/.claude/skills/inline` |
| Other agents | Use the skills directory documented by your agent |

Restart the agent, then connect [Inline MCP](/docs/mcp) or install and authenticate the [Inline CLI](/docs/cli) if the environment does not already provide an Inline access path.

## Source and help

- [Inline plugin source](https://github.com/inline-chat/inline/tree/main/plugins/inline)
- [Inline skill source](https://github.com/inline-chat/inline/tree/main/skills/inline)
- [`skills` CLI documentation](https://skills.sh/docs/cli)
- [Inline MCP setup](/docs/mcp)
