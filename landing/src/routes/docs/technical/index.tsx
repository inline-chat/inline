import { createFileRoute } from "@tanstack/react-router"

import { DocsPage, docsPageHead } from "~/docs/DocsPage"

const slug = "technical/index"

export const Route = createFileRoute("/docs/technical/")({
  component: TechnicalDocsIndex,
  head: () => docsPageHead(slug),
})

function TechnicalDocsIndex() {
  return <DocsPage slug={slug} />
}
