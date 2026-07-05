import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/openclaw.md")({
  server: {
    handlers: docsMarkdownHandlers("openclaw"),
  },
})
