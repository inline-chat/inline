import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/realtime-sync")({
  component: RealtimeSyncDocs,
  head: () => docsPageHead("realtime-sync"),
})

function RealtimeSyncDocs() {
  return <DocsPage slug="realtime-sync" />
}
