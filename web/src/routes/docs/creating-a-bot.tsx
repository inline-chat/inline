import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import creatingABot from "~/docs/content/creating-a-bot.md?raw"

export const Route = createFileRoute("/docs/creating-a-bot")({
  component: CreatingABotDocs,
  head: () => ({
    meta: [{ title: "Creating a Bot - Inline Docs" }],
  }),
})

function CreatingABotDocs() {
  return <DocsMarkdown markdown={creatingABot} className="page-content docs-content" />
}
