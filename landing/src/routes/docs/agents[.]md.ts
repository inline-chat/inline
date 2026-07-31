import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/agents.md")({
  server: {
    handlers: docsMarkdownHandlers("agents"),
  },
})
