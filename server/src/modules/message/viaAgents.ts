/**
 * Agents that can send messages for a person, shown as "Sent via <name>".
 * Ids match the CLI's agent detection (cli/src/agent_context.rs) and the
 * OAuth clients the MCP server recognizes. Names are never taken from a
 * client, so nobody can send "via Inline Support".
 */
export const VIA_AGENTS: Readonly<Record<string, string>> = {
  "claude-code": "Claude Code",
  codex: "Codex",
  "cursor-agent": "Cursor",
  "gemini-cli": "Gemini CLI",
  amp: "Amp",
  opencode: "OpenCode",
  auggie: "Auggie",
  crush: "Crush",
  copilot: "GitHub Copilot",
  "qwen-code": "Qwen Code",
  pi: "Pi",
  warp: "Warp",
  chatgpt: "ChatGPT",
  claude: "Claude",
  agent: "an AI agent",
}

/** The id for an agent this server doesn't know by name. */
export const GENERIC_VIA_AGENT = "agent"

export const knownViaApp = (app: string): string => {
  const id = app.trim().toLowerCase()
  return Object.hasOwn(VIA_AGENTS, id) ? id : GENERIC_VIA_AGENT
}
