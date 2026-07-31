import { DocsMarkdown } from "~/docs/DocsMarkdown"
import { type DocsPageSlug, requireDocsPage } from "~/docs/pages"

export function docsPageHead(slug: DocsPageSlug) {
  const page = requireDocsPage(slug)
  return {
    meta: [{ title: `${page.title} - Inline Docs` }],
  }
}

export function DocsPage({ slug }: { slug: DocsPageSlug }) {
  const page = requireDocsPage(slug)
  const isChangelog = slug === "changelog"
  const isIndex = slug === "index" || slug === "agents"
  const className = `page-content docs-content${isChangelog ? " changelog-content" : ""}${isIndex ? " docs-index-content" : ""}`
  return <DocsMarkdown markdown={page.markdown} className={className} renderVideoLinks={isChangelog} />
}
