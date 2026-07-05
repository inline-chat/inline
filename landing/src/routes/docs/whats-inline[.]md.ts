import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/whats-inline.md")({
  server: {
    handlers: docsMarkdownHandlers("whats-inline"),
  },
})
