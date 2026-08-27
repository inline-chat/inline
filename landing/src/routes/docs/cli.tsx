import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/cli")({
  loader: () => {
    requireDocsPage("cli")
  },
  component: CliDocs,
  head: () => docsPageHead("cli"),
})

function CliDocs() {
  return <DocsPage slug="cli" />
}
