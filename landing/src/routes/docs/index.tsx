import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/")({
  loader: () => {
    requireDocsPage("index")
  },
  component: WelcomeDocs,
  head: () => docsPageHead("index"),
})

function WelcomeDocs() {
  return <DocsPage slug="index" />
}
