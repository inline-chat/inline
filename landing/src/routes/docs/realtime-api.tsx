import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/realtime-api")({
  component: RealtimeApiDocs,
  head: () => docsPageHead("realtime-api"),
})

function RealtimeApiDocs() {
  return <DocsPage slug="realtime-api" />
}
