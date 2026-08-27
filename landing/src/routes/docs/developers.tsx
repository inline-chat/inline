import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/developers")({
  loader: () => {
    requireDocsPage("developers")
  },
  component: DevelopersDocs,
  head: () => docsPageHead("developers"),
})

function DevelopersDocs() {
  return <DocsPage slug="developers" />
}
