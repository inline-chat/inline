import { createFileRoute } from "@tanstack/react-router"

import { docsMarkdownHeadResponse, docsMarkdownResponse } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/docs/technical/{$slug}.md")({
  server: {
    handlers: {
      GET: ({ params }) => docsMarkdownResponse(`technical/${params.slug}`),
      HEAD: ({ params }) => docsMarkdownHeadResponse(`technical/${params.slug}`),
    },
  },
})
