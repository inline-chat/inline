import { notFound } from "@tanstack/react-router"
import { createDocsPages, type DocsPage } from "./catalog"
import docsSources from "virtual:inline-docs-content"

export const ALL_DOCS_PAGES = createDocsPages(
  Object.entries(docsSources).map(([path, markdown]) => ({ path, markdown })),
)

export const PUBLISHED_DOCS_PAGES = ALL_DOCS_PAGES.filter((page) => !page.draft)
export const DOCS_INCLUDE_DRAFTS = import.meta.env.DEV
export const DOCS_PAGES = DOCS_INCLUDE_DRAFTS ? ALL_DOCS_PAGES : PUBLISHED_DOCS_PAGES

export type { DocsPage }
export type DocsPageSlug = string

export function getDocsPage(slug: string): DocsPage | undefined {
  return DOCS_PAGES.find((page) => page.slug === slug)
}

export function getPublishedDocsPage(slug: string): DocsPage | undefined {
  return PUBLISHED_DOCS_PAGES.find((page) => page.slug === slug)
}

export function requireDocsPage(slug: string): DocsPage {
  const page = getDocsPage(slug)
  if (!page) throw notFound()
  return page
}
