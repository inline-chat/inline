import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import whatsInline from "~/docs/content/whats-inline.md?raw"

export const Route = createFileRoute("/docs/whats-inline")({
  component: WhatsInlineDocs,
  head: () => ({
    meta: [{ title: "What's Inline - Inline Docs" }],
  }),
})

function WhatsInlineDocs() {
  return <DocsMarkdown markdown={whatsInline} className="page-content docs-content" />
}
