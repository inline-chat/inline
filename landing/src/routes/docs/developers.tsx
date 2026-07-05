import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/developers")({
  component: DevelopersDocs,
  head: () => docsPageHead("developers"),
})

function DevelopersDocs() {
  return <DocsPage slug="developers" />
}
