import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/index.md")({
  server: {
    handlers: docsMarkdownHandlers("index"),
  },
})
