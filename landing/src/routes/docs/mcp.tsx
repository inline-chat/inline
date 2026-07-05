import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/mcp")({
  component: McpDocs,
  head: () => docsPageHead("mcp"),
})

function McpDocs() {
  return <DocsPage slug="mcp" />
}
