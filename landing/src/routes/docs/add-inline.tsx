import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/add-inline")({
  component: AddInlineDocs,
  head: () => docsPageHead("add-inline"),
})

function AddInlineDocs() {
  return <DocsPage slug="add-inline" />
}
