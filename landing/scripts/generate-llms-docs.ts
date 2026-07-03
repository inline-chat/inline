import { mkdir, readFile, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const landingRoot = fileURLToPath(new URL("..", import.meta.url))
const docsSourceDir = join(landingRoot, "src/docs/content")
const publicDir = join(landingRoot, "public")
const docsMarkdownDir = join(publicDir, "docs")
const origin = "https://inline.chat"

type DocPage = {
  title: string
  source: string
  route: string
  markdownPath: string
  summary: string
}

const pages: DocPage[] = [
  {
    title: "Welcome",
    source: "welcome.md",
    route: "/docs",
    markdownPath: "/docs/index.md",
    summary: "Start here for Inline docs and product status.",
  },
  {
    title: "What's Inline",
    source: "whats-inline.md",
    route: "/docs/whats-inline",
    markdownPath: "/docs/whats-inline.md",
    summary: "Product goals and design principles.",
  },
  {
    title: "Downloads",
    source: "downloads.md",
    route: "/docs/downloads",
    markdownPath: "/docs/downloads.md",
    summary: "Current app download links.",
  },
  {
    title: "Roadmap",
    source: "roadmap.md",
    route: "/docs/roadmap",
    markdownPath: "/docs/roadmap.md",
    summary: "Current product roadmap status.",
  },
  {
    title: "CLI",
    source: "cli.md",
    route: "/docs/cli",
    markdownPath: "/docs/cli.md",
    summary: "Install and authenticate the Inline command line tool.",
  },
  {
    title: "Developers",
    source: "developers.md",
    route: "/docs/developers",
    markdownPath: "/docs/developers.md",
    summary: "Overview of Inline developer surfaces.",
  },
  {
    title: "Realtime API",
    source: "realtime-api.md",
    route: "/docs/realtime-api",
    markdownPath: "/docs/realtime-api.md",
    summary: "WebSocket API and TypeScript SDK quick start.",
  },
  {
    title: "Bot API",
    source: "bot-api.md",
    route: "/docs/bot-api",
    markdownPath: "/docs/bot-api.md",
    summary: "HTTP API for bot integrations and automations.",
  },
  {
    title: "Creating a Bot",
    source: "creating-a-bot.md",
    route: "/docs/creating-a-bot",
    markdownPath: "/docs/creating-a-bot.md",
    summary: "Create or reveal an Inline bot token.",
  },
  {
    title: "MCP",
    source: "mcp.md",
    route: "/docs/mcp",
    markdownPath: "/docs/mcp.md",
    summary: "Connect MCP-compatible agents to Inline with OAuth consent.",
  },
  {
    title: "OpenClaw",
    source: "openclaw.md",
    route: "/docs/openclaw",
    markdownPath: "/docs/openclaw.md",
    summary: "Configure the official Inline OpenClaw plugin.",
  },
  {
    title: "Hermes Agent",
    source: "hermes.md",
    route: "/docs/hermes",
    markdownPath: "/docs/hermes.md",
    summary: "Run Hermes Agent from Inline chats.",
  },
  {
    title: "Security",
    source: "security.md",
    route: "/docs/security",
    markdownPath: "/docs/security.md",
    summary: "Security posture, encryption, and vulnerability reporting.",
  },
]

function absoluteLinks(markdown: string): string {
  return markdown.replace(/\]\((\/[^)\s]+)\)/g, `](${origin}$1)`)
}

function withoutH1(markdown: string): string {
  return markdown.replace(/^# .+\n+/, "").trim()
}

function pageMarkdown(page: DocPage, markdown: string): string {
  return [`# ${page.title}`, "", `Source: ${origin}${page.route}`, "", withoutH1(absoluteLinks(markdown)), ""].join("\n")
}

async function main() {
  await mkdir(docsMarkdownDir, { recursive: true })

  const pageBodies = await Promise.all(
    pages.map(async (page) => {
      const source = await readFile(join(docsSourceDir, page.source), "utf8")
      const markdown = pageMarkdown(page, source)
      const outputPath = join(publicDir, page.markdownPath)
      await mkdir(dirname(outputPath), { recursive: true })
      await writeFile(outputPath, markdown)
      return { page, markdown }
    }),
  )

  const docsList = pages
    .map((page) => `- [${page.title}](${origin}${page.markdownPath}): ${page.summary}`)
    .join("\n")

  const llmsTxt = [
    "# Inline",
    "",
    "> Inline is a work chat app for teams and agents. Use these docs for app setup, developer APIs, the hosted MCP server, CLI, and integrations.",
    "",
    "## Docs",
    "",
    docsList,
    "",
    "## Machine-readable References",
    "",
    `- [Full docs corpus](${origin}/llms-full.txt): All public docs concatenated as Markdown.`,
    `- [OpenAPI spec](${origin}/openapi.json): Bot HTTP API schema.`,
    `- [Integration declaration](${origin}/.well-known/integrations.json): Machine-readable integration metadata.`,
    `- [MCP server card](${origin}/.well-known/mcp/server-card.json): Hosted MCP endpoint and OAuth metadata.`,
    "",
  ].join("\n")

  await writeFile(join(publicDir, "llms.txt"), llmsTxt)

  const llmsFull = [
    "# Inline Docs",
    "",
    `Source: ${origin}`,
    "",
    "Generated from the same Markdown files used by the HTML docs.",
    "",
    "## Contents",
    "",
    docsList,
    "",
    ...pageBodies.flatMap(({ markdown }) => [markdown.trim(), ""]),
  ].join("\n")

  await writeFile(join(publicDir, "llms-full.txt"), llmsFull)
}

await main()
