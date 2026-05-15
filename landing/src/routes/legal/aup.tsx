import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import aup from "~/legal/content/aup.md?raw"

export const Route = createFileRoute("/legal/aup")({
  component: Aup,
  head: () => ({
    meta: [
      { title: "Acceptable Use Policy - Inline" },
      {
        name: "description",
        content: "Acceptable use rules for Inline.",
      },
    ],
  }),
})

function Aup() {
  return <DocsMarkdown markdown={aup} className="page-content docs-content legal-content" />
}
