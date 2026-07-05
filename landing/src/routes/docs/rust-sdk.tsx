import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/rust-sdk")({
  component: RustSdkDocs,
  head: () => docsPageHead("rust-sdk"),
})

function RustSdkDocs() {
  return <DocsPage slug="rust-sdk" />
}
