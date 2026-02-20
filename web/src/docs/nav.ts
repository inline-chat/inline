export type DocsNavGroup = {
  title: string
  items: Array<{
    title: string
    to: string
  }>
}

export const DOCS_NAV: DocsNavGroup[] = [
  {
    title: "Getting Started",
    items: [
      { title: "Welcome", to: "/docs" },
      { title: "What's Inline", to: "/docs/whats-inline" },
      { title: "Roadmap", to: "/docs/roadmap" },
      { title: "Downloads", to: "/docs/downloads" },
      { title: "CLI", to: "/docs/cli" },
    ],
  },
  {
    title: "Developers",
    items: [
      { title: "Overview", to: "/docs/developers" },
      { title: "Realtime API", to: "/docs/realtime-api" },
      { title: "Bot API", to: "/docs/bot-api" },
      { title: "Creating a Bot", to: "/docs/creating-a-bot" },
    ],
  },
  {
    title: "Integrations",
    items: [
      { title: "MCP", to: "/docs/mcp" },
      { title: "OpenClaw", to: "/docs/openclaw" },
    ],
  },
  {
    title: "Policies",
    items: [
      { title: "Terms", to: "/docs/terms" },
      { title: "Security", to: "/docs/security" },
      { title: "Privacy", to: "/privacy" },
    ],
  },
]
