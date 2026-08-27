import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/whats-inline")({
  loader: () => {
    requireDocsPage("whats-inline")
  },
  component: WhatsInlineDocs,
  head: () => docsPageHead("whats-inline"),
})

function WhatsInlineDocs() {
  return <DocsPage slug="whats-inline" />
}
