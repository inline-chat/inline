import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/security")({
  loader: () => {
    requireDocsPage("security")
  },
  component: SecurityDocs,
  head: () => docsPageHead("security"),
})

function SecurityDocs() {
  return <DocsPage slug="security" />
}
