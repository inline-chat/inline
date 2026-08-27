import { DocsMarkdown } from "~/docs/DocsMarkdown"
import { requireDocsPage } from "~/docs/pages"

export function docsPageHead(slug: string) {
  const page = requireDocsPage(slug)
  return {
    meta: [
      { title: `${page.title} - Inline Docs` },
      { name: "description", content: page.description },
      ...(page.draft ? [{ name: "robots", content: "noindex,nofollow" }] : []),
    ],
  }
}

export function DocsPage({ slug }: { slug: string }) {
  const page = requireDocsPage(slug)
  const isChangelog = slug === "changelog"
  const className = `page-content docs-content${isChangelog ? " changelog-content" : ""}`
  return (
    <DocsMarkdown
      markdown={page.markdown}
      className={className}
      renderVideoLinks={isChangelog}
      metadata={{ ...page.frontMatter, draft: page.draft }}
    />
  )
}
