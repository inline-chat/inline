import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import terms from "~/docs/content/terms.md?raw"

export const Route = createFileRoute("/docs/terms")({
  component: TermsDocs,
  head: () => ({
    meta: [{ title: "Terms - Inline Docs" }],
  }),
})

function TermsDocs() {
  return <DocsMarkdown markdown={terms} className="page-content docs-content" />
}

