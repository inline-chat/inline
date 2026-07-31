import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/add-inline.md")({
  server: {
    handlers: docsMarkdownHandlers("add-inline"),
  },
})
