import { createFileRoute } from "@tanstack/react-router"

import { llmsTxtResponse, markdownHeadResponse } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/llms.txt")({
  server: {
    handlers: {
      GET: async () => llmsTxtResponse(),
      HEAD: async () => markdownHeadResponse(),
    },
  },
})
