import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/bot-api")({
  component: BotApiDocs,
  head: () => docsPageHead("bot-api"),
})

function BotApiDocs() {
  return <DocsPage slug="bot-api" />
}
