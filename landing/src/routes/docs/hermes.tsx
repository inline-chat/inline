import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import hermes from "~/docs/content/hermes.md?raw"

export const Route = createFileRoute("/docs/hermes")({
  component: HermesDocs,
  head: () => ({
    meta: [{ title: "Hermes Agent - Inline Docs" }],
  }),
})

function HermesDocs() {
  return <DocsMarkdown markdown={hermes} className="page-content docs-content" />
}
