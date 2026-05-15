import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import dpa from "~/legal/content/dpa.md?raw"

export const Route = createFileRoute("/legal/dpa")({
  component: Dpa,
  head: () => ({
    meta: [
      { title: "Data Processing Addendum - Inline" },
      {
        name: "description",
        content: "Data processing terms for customers using Inline.",
      },
    ],
  }),
})

function Dpa() {
  return <DocsMarkdown markdown={dpa} className="page-content docs-content legal-content" />
}
