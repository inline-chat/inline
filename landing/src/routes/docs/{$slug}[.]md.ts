import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHeadResponse, docsMarkdownResponse } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/{$slug}.md")({
  server: {
    handlers: {
      GET: ({ params }) => docsMarkdownResponse(params.slug),
      HEAD: ({ params }) => docsMarkdownHeadResponse(params.slug),
    },
  },
})
