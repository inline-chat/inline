import botApi from "./content/bot-api.md?raw"
import addInline from "./content/add-inline.md?raw"
import agents from "./content/agents.md?raw"
import changelog from "./content/changelog.md?raw"
import cli from "./content/cli.md?raw"
import creatingABot from "./content/creating-a-bot.md?raw"
import developers from "./content/developers.md?raw"
import downloads from "./content/downloads.md?raw"
import hermes from "./content/hermes.md?raw"
import mcp from "./content/mcp.md?raw"
import openclaw from "./content/openclaw.md?raw"
import realtimeApi from "./content/realtime-api.md?raw"
import roadmap from "./content/roadmap.md?raw"
import rustSdk from "./content/rust-sdk.md?raw"
import security from "./content/security.md?raw"
import welcome from "./content/welcome.md?raw"
import whatsInline from "./content/whats-inline.md?raw"

export const DOCS_NAV_GROUPS = [
  { id: "getting-started", title: "Getting Started" },
  { id: "agents", title: "Agents" },
  { id: "developers", title: "Developers" },
  { id: "policies", title: "Policies" },
] as const

type DocsNavGroupId = (typeof DOCS_NAV_GROUPS)[number]["id"]

type DocsPageDefinition = {
  slug: string
  title: string
  navTitle?: string
  navHidden?: boolean
  route: "/docs" | `/docs/${string}`
  markdownPath: `/docs/${string}.md`
  summary: string
  navGroup: DocsNavGroupId
  markdown: string
}

export const DOCS_PAGES = [
  {
    slug: "index",
    title: "Get Started",
    route: "/docs",
    markdownPath: "/docs/index.md",
    summary: "Install Inline and connect your first agent.",
    navGroup: "getting-started",
    markdown: welcome,
  },
  {
    slug: "whats-inline",
    title: "What's Inline",
    route: "/docs/whats-inline",
    markdownPath: "/docs/whats-inline.md",
    summary: "Product goals and design principles.",
    navHidden: true,
    navGroup: "getting-started",
    markdown: whatsInline,
  },
  {
    slug: "roadmap",
    title: "Roadmap",
    route: "/docs/roadmap",
    markdownPath: "/docs/roadmap.md",
    summary: "Current product roadmap status.",
    navHidden: true,
    navGroup: "getting-started",
    markdown: roadmap,
  },
  {
    slug: "agents",
    title: "Agents",
    navTitle: "Overview",
    route: "/docs/agents",
    markdownPath: "/docs/agents.md",
    summary: "Connect coding agents and agent platforms to Inline.",
    navGroup: "agents",
    markdown: agents,
  },
  {
    slug: "add-inline",
    title: "Add Inline to Your Agent",
    navTitle: "Add Inline",
    route: "/docs/add-inline",
    markdownPath: "/docs/add-inline.md",
    summary: "Install the Inline plugin or skill for ChatGPT, Codex, Claude, and other agents.",
    navGroup: "agents",
    markdown: addInline,
  },
  {
    slug: "changelog",
    title: "What's New",
    route: "/docs/changelog",
    markdownPath: "/docs/changelog.md",
    summary: "Release notes and exact app build links.",
    navGroup: "getting-started",
    markdown: changelog,
  },
  {
    slug: "downloads",
    title: "Downloads",
    route: "/docs/downloads",
    markdownPath: "/docs/downloads.md",
    summary: "Current app download links.",
    navGroup: "getting-started",
    markdown: downloads,
  },
  {
    slug: "cli",
    title: "CLI",
    route: "/docs/cli",
    markdownPath: "/docs/cli.md",
    summary: "Install and authenticate the Inline command line tool.",
    navGroup: "getting-started",
    markdown: cli,
  },
  {
    slug: "developers",
    title: "Developers",
    navTitle: "Overview",
    route: "/docs/developers",
    markdownPath: "/docs/developers.md",
    summary: "Overview of Inline developer surfaces.",
    navGroup: "developers",
    markdown: developers,
  },
  {
    slug: "realtime-api",
    title: "Realtime API",
    route: "/docs/realtime-api",
    markdownPath: "/docs/realtime-api.md",
    summary: "WebSocket API and TypeScript SDK quick start.",
    navGroup: "developers",
    markdown: realtimeApi,
  },
  {
    slug: "rust-sdk",
    title: "Rust SDK",
    route: "/docs/rust-sdk",
    markdownPath: "/docs/rust-sdk.md",
    summary: "Rust SDK quick start for API calls, uploads, and realtime RPC.",
    navGroup: "developers",
    markdown: rustSdk,
  },
  {
    slug: "bot-api",
    title: "Bot API",
    route: "/docs/bot-api",
    markdownPath: "/docs/bot-api.md",
    summary: "HTTP API for bot integrations and automations.",
    navGroup: "developers",
    markdown: botApi,
  },
  {
    slug: "creating-a-bot",
    title: "Create a Bot",
    route: "/docs/creating-a-bot",
    markdownPath: "/docs/creating-a-bot.md",
    summary: "Create or reveal an Inline bot token.",
    navGroup: "developers",
    markdown: creatingABot,
  },
  {
    slug: "mcp",
    title: "MCP",
    route: "/docs/mcp",
    markdownPath: "/docs/mcp.md",
    summary: "Connect MCP-compatible agents to Inline with OAuth consent.",
    navGroup: "agents",
    markdown: mcp,
  },
  {
    slug: "openclaw",
    title: "OpenClaw",
    route: "/docs/openclaw",
    markdownPath: "/docs/openclaw.md",
    summary: "Configure the official Inline OpenClaw plugin.",
    navGroup: "agents",
    markdown: openclaw,
  },
  {
    slug: "hermes",
    title: "Hermes Agent",
    route: "/docs/hermes",
    markdownPath: "/docs/hermes.md",
    summary: "Run Hermes Agent from Inline chats.",
    navGroup: "agents",
    markdown: hermes,
  },
  {
    slug: "security",
    title: "Security",
    route: "/docs/security",
    markdownPath: "/docs/security.md",
    summary: "Security posture, encryption, and vulnerability reporting.",
    navGroup: "policies",
    markdown: security,
  },
] as const satisfies readonly DocsPageDefinition[]

export type DocsPage = (typeof DOCS_PAGES)[number]
export type DocsPageSlug = DocsPage["slug"]

export function getDocsPage(slug: string): DocsPage | undefined {
  return DOCS_PAGES.find((page) => page.slug === slug)
}

export function requireDocsPage(slug: DocsPageSlug): DocsPage {
  const page = getDocsPage(slug)
  if (!page) {
    throw new Error(`Unknown docs page: ${slug}`)
  }
  return page
}
