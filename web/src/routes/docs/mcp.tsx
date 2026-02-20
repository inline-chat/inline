import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import mcp from "~/docs/content/mcp.md?raw"

export const Route = createFileRoute("/docs/mcp")({
  component: McpDocs,
  head: () => ({
    meta: [{ title: "MCP - Inline Docs" }],
  }),
})

function McpDocs() {
  return <DocsMarkdown markdown={mcp} className="page-content docs-content" />
}
