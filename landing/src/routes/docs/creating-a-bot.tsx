import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/creating-a-bot")({
  loader: () => {
    requireDocsPage("creating-a-bot")
  },
  component: CreatingABotDocs,
  head: () => docsPageHead("creating-a-bot"),
})

function CreatingABotDocs() {
  return <DocsPage slug="creating-a-bot" />
}
