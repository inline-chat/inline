import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import subprocessors from "~/legal/content/subprocessors.md?raw"

export const Route = createFileRoute("/legal/subprocessors")({
  component: Subprocessors,
  head: () => ({
    meta: [
      { title: "Subprocessors - Inline" },
      {
        name: "description",
        content: "Third-party providers used to operate Inline.",
      },
    ],
  }),
})

function Subprocessors() {
  return <DocsMarkdown markdown={subprocessors} className="page-content docs-content legal-content" />
}
