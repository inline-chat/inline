import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/")({
  component: WelcomeDocs,
  head: () => docsPageHead("index"),
})

function WelcomeDocs() {
  return <DocsPage slug="index" />
}
