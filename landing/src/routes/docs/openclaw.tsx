import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/openclaw")({
  component: OpenClawDocs,
  head: () => docsPageHead("openclaw"),
})

function OpenClawDocs() {
  return <DocsPage slug="openclaw" />
}
