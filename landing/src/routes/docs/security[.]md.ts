import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/security.md")({
  server: {
    handlers: docsMarkdownHandlers("security"),
  },
})
