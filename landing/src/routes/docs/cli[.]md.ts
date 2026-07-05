import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/cli.md")({
  server: {
    handlers: docsMarkdownHandlers("cli"),
  },
})
