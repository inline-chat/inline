import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/cli")({
  component: CliDocs,
  head: () => docsPageHead("cli"),
})

function CliDocs() {
  return <DocsPage slug="cli" />
}
