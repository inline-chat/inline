import { DOCS_PAGES, getDocsPage, type DocsPage, type DocsPageSlug } from "~/docs/pages"

const origin = "https://inline.chat"

const PUBLIC_MARKDOWN_HEADERS = {
  "content-type": "text/markdown; charset=utf-8",
}

function absoluteLinks(markdown: string): string {
  return markdown.replace(/\]\((\/[^)\s]+)\)/g, `](${origin}$1)`)
}

function withoutH1(markdown: string): string {
  return markdown.replace(/^# .+\n+/, "").trim()
}

export function publicDocsPageMarkdown(page: DocsPage): string {
  return [`# ${page.title}`, "", `Source: ${origin}${page.route}`, "", withoutH1(absoluteLinks(page.markdown)), ""].join("\n")
}

function docsList(): string {
  return DOCS_PAGES.map((page) => `- [${page.title}](${origin}${page.markdownPath}): ${page.summary}`).join("\n")
}

export function llmsTxtMarkdown(): string {
  return [
    "# Inline",
    "",
    "> Inline is a work chat app for teams and agents. Use these docs for app setup, developer APIs, the hosted MCP server, CLI, and integrations.",
    "",
    "## Docs",
    "",
    docsList(),
    "",
    "## Machine-readable References",
    "",
    `- [Full docs corpus](${origin}/llms-full.txt): All public docs concatenated as Markdown.`,
    `- [OpenAPI spec](${origin}/openapi.json): Bot HTTP API schema.`,
    `- [Integration declaration](${origin}/.well-known/integrations.json): Machine-readable integration metadata.`,
    `- [MCP server card](${origin}/.well-known/mcp/server-card.json): Hosted MCP endpoint and OAuth metadata.`,
    "",
  ].join("\n")
}

export function llmsFullTxtMarkdown(): string {
  return [
    "# Inline Docs",
    "",
    `Source: ${origin}`,
    "",
    "Generated from the same Markdown files used by the HTML docs.",
    "",
    "## Contents",
    "",
    docsList(),
    "",
    ...DOCS_PAGES.flatMap((page) => [publicDocsPageMarkdown(page).trim(), ""]),
  ].join("\n")
}

export function docsMarkdownResponse(slug: string): Response {
  const page = getDocsPage(slug)
  if (!page) {
    return new Response("Not found\n", {
      status: 404,
      headers: PUBLIC_MARKDOWN_HEADERS,
    })
  }

  return new Response(publicDocsPageMarkdown(page), {
    headers: PUBLIC_MARKDOWN_HEADERS,
  })
}

export function docsMarkdownHeadResponse(slug: string): Response {
  const page = getDocsPage(slug)
  return new Response(null, {
    status: page ? 200 : 404,
    headers: PUBLIC_MARKDOWN_HEADERS,
  })
}

export function docsMarkdownHandlers(slug: DocsPageSlug) {
  return {
    GET: async () => docsMarkdownResponse(slug),
    HEAD: async () => docsMarkdownHeadResponse(slug),
  }
}

export function llmsTxtResponse(): Response {
  return new Response(llmsTxtMarkdown(), {
    headers: PUBLIC_MARKDOWN_HEADERS,
  })
}

export function llmsFullTxtResponse(): Response {
  return new Response(llmsFullTxtMarkdown(), {
    headers: PUBLIC_MARKDOWN_HEADERS,
  })
}

export function markdownHeadResponse(): Response {
  return new Response(null, {
    headers: PUBLIC_MARKDOWN_HEADERS,
  })
}
