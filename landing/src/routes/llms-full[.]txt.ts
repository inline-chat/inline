import { createFileRoute } from "@tanstack/react-router"

import { llmsFullTxtResponse, markdownHeadResponse } from "~/docs/publicMarkdown"

export const Route = createFileRoute("/llms-full.txt")({
  server: {
    handlers: {
      GET: async () => llmsFullTxtResponse(),
      HEAD: async () => markdownHeadResponse(),
    },
  },
})
