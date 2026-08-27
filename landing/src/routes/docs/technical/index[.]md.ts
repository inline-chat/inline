import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/technical/index.md")({
  server: {
    handlers: docsMarkdownHandlers("technical/index"),
  },
})
