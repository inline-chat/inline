import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import cli from "~/docs/content/cli.md?raw"

export const Route = createFileRoute("/docs/cli")({
  component: CliDocs,
  head: () => ({
    meta: [{ title: "CLI - Inline Docs" }],
  }),
})

function CliDocs() {
  return <DocsMarkdown markdown={cli} className="page-content docs-content" />
}

