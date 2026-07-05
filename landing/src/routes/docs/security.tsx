import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/security")({
  component: SecurityDocs,
  head: () => docsPageHead("security"),
})

function SecurityDocs() {
  return <DocsPage slug="security" />
}
