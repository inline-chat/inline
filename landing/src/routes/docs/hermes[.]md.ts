import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/hermes.md")({
  server: {
    handlers: docsMarkdownHandlers("hermes"),
  },
})
