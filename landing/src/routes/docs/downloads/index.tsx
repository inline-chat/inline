import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import downloads from "~/docs/content/downloads.md?raw"

export const Route = createFileRoute("/docs/downloads/")({
  component: DownloadsDocs,
  head: () => ({
    meta: [{ title: "Downloads - Inline Docs" }],
  }),
})

function DownloadsDocs() {
  return <DocsMarkdown markdown={downloads} className="page-content docs-content" />
}

