import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import privacy from "~/legal/content/privacy.md?raw"

export const Route = createFileRoute("/legal/privacy")({
  component: Privacy,
  head: () => ({
    meta: [
      { title: "Privacy Policy - Inline" },
      {
        name: "description",
        content: "How Inline collects, uses, shares, and protects personal information.",
      },
    ],
  }),
})

function Privacy() {
  return <DocsMarkdown markdown={privacy} className="page-content docs-content legal-content" />
}
