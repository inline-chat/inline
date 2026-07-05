import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/developers.md")({
  server: {
    handlers: docsMarkdownHandlers("developers"),
  },
})
