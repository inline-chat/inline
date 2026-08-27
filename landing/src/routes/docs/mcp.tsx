import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/mcp")({
  loader: () => {
    requireDocsPage("mcp")
  },
  component: McpDocs,
  head: () => docsPageHead("mcp"),
})

function McpDocs() {
  return <DocsPage slug="mcp" />
}
