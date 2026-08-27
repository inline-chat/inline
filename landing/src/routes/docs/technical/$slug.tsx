import { createFileRoute } from "@tanstack/react-router"

import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

function technicalSlug(slug: string) {
  return `technical/${slug}`
}

export const Route = createFileRoute("/docs/technical/$slug")({
  loader: ({ params }) => {
    const slug = technicalSlug(params.slug)
    requireDocsPage(slug)
    return slug
  },
  component: TechnicalDocsPage,
  head: ({ params }) => docsPageHead(technicalSlug(params.slug)),
})

function TechnicalDocsPage() {
  return <DocsPage slug={Route.useLoaderData()} />
}
