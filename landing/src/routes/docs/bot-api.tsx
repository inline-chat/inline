import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/bot-api")({
  loader: () => {
    requireDocsPage("bot-api")
  },
  component: BotApiDocs,
  head: () => docsPageHead("bot-api"),
})

function BotApiDocs() {
  return <DocsPage slug="bot-api" />
}
