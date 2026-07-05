import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/whats-inline")({
  component: WhatsInlineDocs,
  head: () => docsPageHead("whats-inline"),
})

function WhatsInlineDocs() {
  return <DocsPage slug="whats-inline" />
}
