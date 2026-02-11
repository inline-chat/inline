import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import botApi from "~/docs/content/bot-api.md?raw"

export const Route = createFileRoute("/docs/bot-api")({
  component: BotApiDocs,
  head: () => ({
    meta: [{ title: "Bot API - Inline Docs" }],
  }),
})

function BotApiDocs() {
  return <DocsMarkdown markdown={botApi} className="page-content docs-content" />
}

