import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/openclaw")({
  loader: () => {
    requireDocsPage("openclaw")
  },
  component: OpenClawDocs,
  head: () => docsPageHead("openclaw"),
})

function OpenClawDocs() {
  return <DocsPage slug="openclaw" />
}
