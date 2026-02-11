import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import developers from "~/docs/content/developers.md?raw"

export const Route = createFileRoute("/docs/developers")({
  component: DevelopersDocs,
  head: () => ({
    meta: [{ title: "Developers - Inline Docs" }],
  }),
})

function DevelopersDocs() {
  return <DocsMarkdown markdown={developers} className="page-content docs-content" />
}
