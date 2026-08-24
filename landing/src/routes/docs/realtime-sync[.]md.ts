import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/realtime-sync.md")({
  server: {
    handlers: docsMarkdownHandlers("realtime-sync"),
  },
})
