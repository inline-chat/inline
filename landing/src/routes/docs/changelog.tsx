import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/changelog")({
  loader: () => {
    requireDocsPage("changelog")
  },
  component: ChangelogDocs,
  head: () => docsPageHead("changelog"),
})

function ChangelogDocs() {
  return <DocsPage slug="changelog" />
}
