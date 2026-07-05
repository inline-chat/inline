import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/realtime-api.md")({
  server: {
    handlers: docsMarkdownHandlers("realtime-api"),
  },
})
