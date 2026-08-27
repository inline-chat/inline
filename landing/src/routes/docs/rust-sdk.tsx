import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/rust-sdk")({
  loader: () => {
    requireDocsPage("rust-sdk")
  },
  component: RustSdkDocs,
  head: () => docsPageHead("rust-sdk"),
})

function RustSdkDocs() {
  return <DocsPage slug="rust-sdk" />
}
