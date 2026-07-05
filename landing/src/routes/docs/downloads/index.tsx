import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/downloads/")({
  component: DownloadsDocs,
  head: () => docsPageHead("downloads"),
})

function DownloadsDocs() {
  return <DocsPage slug="downloads" />
}
