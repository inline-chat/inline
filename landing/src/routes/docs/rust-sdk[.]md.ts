import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHandlers } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/rust-sdk.md")({
  server: {
    handlers: docsMarkdownHandlers("rust-sdk"),
  },
})
