import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/hermes")({
  loader: () => {
    requireDocsPage("hermes")
  },
  component: HermesDocs,
  head: () => docsPageHead("hermes"),
})

function HermesDocs() {
  return <DocsPage slug="hermes" />
}
