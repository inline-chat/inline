import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/hermes")({
  component: HermesDocs,
  head: () => docsPageHead("hermes"),
})

function HermesDocs() {
  return <DocsPage slug="hermes" />
}
