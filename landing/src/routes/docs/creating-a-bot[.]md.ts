import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/creating-a-bot.md")({
  server: {
    handlers: docsMarkdownHandlers("creating-a-bot"),
  },
})
