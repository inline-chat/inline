import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/changelog")({
  component: ChangelogDocs,
  head: () => docsPageHead("changelog"),
})

function ChangelogDocs() {
  return <DocsPage slug="changelog" />
}
