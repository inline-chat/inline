import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import welcome from "~/docs/content/welcome.md?raw"

export const Route = createFileRoute("/docs/")({
  component: WelcomeDocs,
  head: () => ({
    meta: [{ title: "Welcome - Inline Docs" }],
  }),
})

function WelcomeDocs() {
  return <DocsMarkdown markdown={welcome} className="page-content docs-content" />
}

