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
  const className = `page-content docs-content${isChangelog ? " changelog-content" : ""}`
  return <DocsMarkdown markdown={page.markdown} className={className} renderVideoLinks={isChangelog} />
}
