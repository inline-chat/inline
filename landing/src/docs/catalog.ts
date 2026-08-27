import { resolveDocsMarkdown, type DocsFrontMatter } from "./frontMatter"

export type DocsPage = {
  slug: string
  title: string
  description: string
  route: "/docs" | `/docs/${string}`
  markdownPath: `/docs/${string}.md`
  markdown: string
  frontMatter: DocsFrontMatter
  draft: boolean
}

export type DocsSource = {
  path: string
  markdown: string
}

const SLUG_SEGMENT_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export function docsSlugFromPath(path: string): string {
  const normalizedPath = path.replaceAll("\\", "/")
  const contentMarker = "/content/"
  const contentIndex = normalizedPath.lastIndexOf(contentMarker)
  if (contentIndex < 0 || !normalizedPath.endsWith(".md")) {
    throw new Error(`Docs source is not a Markdown file under content/: ${path}`)
  }

  const slug = normalizedPath.slice(contentIndex + contentMarker.length, -3)
  if (slug.split("/").some((segment) => !SLUG_SEGMENT_PATTERN.test(segment))) {
    throw new Error(`Docs path must use lowercase kebab-case segments: ${path}`)
  }
  return slug
}

function docsRoute(slug: string): DocsPage["route"] {
  if (slug === "index") return "/docs"
  if (slug.endsWith("/index")) return `/docs/${slug.slice(0, -"/index".length)}`
  return `/docs/${slug}`
}

export function createDocsPage(source: DocsSource): DocsPage {
  const slug = docsSlugFromPath(source.path)
  let resolved
  try {
    resolved = resolveDocsMarkdown(source.markdown)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(`Invalid docs page ${source.path}: ${message}`)
  }

  return {
    slug,
    title: resolved.title,
    description: resolved.description,
    route: docsRoute(slug),
    markdownPath: `/docs/${slug}.md`,
    markdown: resolved.markdown,
    frontMatter: resolved.frontMatter,
    draft: resolved.frontMatter.draft,
  }
}

export function createDocsPages(sources: DocsSource[]): DocsPage[] {
  const pages = sources.map(createDocsPage).sort((lhs, rhs) => lhs.slug.localeCompare(rhs.slug))
  const slugs = new Set<string>()
  for (const page of pages) {
    if (slugs.has(page.slug)) throw new Error(`Duplicate docs slug: ${page.slug}`)
    slugs.add(page.slug)
  }
  if (!slugs.has("index")) throw new Error("Docs require content/index.md")
  return pages
}
