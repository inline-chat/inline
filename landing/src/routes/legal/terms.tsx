import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import terms from "~/legal/content/terms.md?raw"

export const Route = createFileRoute("/legal/terms")({
  component: Terms,
  head: () => ({
    meta: [
      { title: "Terms of Service - Inline" },
      {
        name: "description",
        content: "Terms and conditions for using Inline.",
      },
    ],
  }),
})

function Terms() {
  return <DocsMarkdown markdown={terms} className="page-content docs-content legal-content" />
}
