import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/downloads.md")({
  server: {
    handlers: docsMarkdownHandlers("downloads"),
  },
})
