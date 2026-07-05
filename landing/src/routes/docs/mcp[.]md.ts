import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/mcp.md")({
  server: {
    handlers: docsMarkdownHandlers("mcp"),
  },
})
