import type { DocsPage } from "./catalog"

export type DocsNavItem = {
  title: string
  to: string
  external?: boolean
  draft?: boolean
}

export type DocsNavGroup = {
  title: string
  items: DocsNavItem[]
}

export type ResolvedDocsSidebar = {
  groups: DocsNavGroup[]
  orderedPages: DocsPage[]
}

type SidebarPageReference = string | { slug: string; label?: string } | { label: string; href: string; external?: boolean }

function objectValue(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}

function stringValue(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) throw new Error(`${label} must be a non-empty string`)
  return value.trim()
}

function hrefValue(value: unknown, label: string): string {
  const href = stringValue(value, label)
  if (!href.startsWith("/") && !/^https?:\/\//i.test(href)) {
    throw new Error(`${label} must be a root-relative or HTTP(S) URL`)
  }
  return href
}

function assertKeys(value: Record<string, unknown>, allowed: string[], label: string) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error(`${label} has unsupported field: ${key}`)
  }
}

function pageReference(value: unknown, label: string): SidebarPageReference {
  if (typeof value === "string") return stringValue(value, label)
  const object = objectValue(value, label)
  if ("slug" in object) {
    assertKeys(object, ["slug", "label"], label)
    return {
      slug: stringValue(object.slug, `${label}.slug`),
      label: object.label === undefined ? undefined : stringValue(object.label, `${label}.label`),
    }
  }

  assertKeys(object, ["label", "href", "external"], label)
  if (object.external !== undefined && typeof object.external !== "boolean") {
    throw new Error(`${label}.external must be true or false`)
  }
  return {
    label: stringValue(object.label, `${label}.label`),
    href: hrefValue(object.href, `${label}.href`),
    external: object.external,
  }
}

export function resolveDocsSidebar(rawConfig: unknown, pages: DocsPage[], includeDrafts: boolean): ResolvedDocsSidebar {
  const config = objectValue(rawConfig, "Docs sidebar")
  assertKeys(config, ["$schema", "groups"], "Docs sidebar")
  if (config.$schema !== undefined) stringValue(config.$schema, "Docs sidebar.$schema")
  if (!Array.isArray(config.groups)) throw new Error("Docs sidebar groups must be an array")

  const pagesBySlug = new Map(pages.map((page) => [page.slug, page]))
  const referencedSlugs = new Set<string>()
  const groupTitles = new Set<string>()
  const orderedPages: DocsPage[] = []

  const groups = config.groups.flatMap((rawGroup, groupIndex): DocsNavGroup[] => {
    const group = objectValue(rawGroup, `Docs sidebar group ${groupIndex + 1}`)
    assertKeys(group, ["title", "pages"], `Docs sidebar group ${groupIndex + 1}`)
    const title = stringValue(group.title, `Docs sidebar group ${groupIndex + 1}.title`)
    if (groupTitles.has(title)) throw new Error(`Duplicate docs sidebar group: ${title}`)
    groupTitles.add(title)
    if (!Array.isArray(group.pages)) throw new Error(`Docs sidebar group ${title}.pages must be an array`)

    const items = group.pages.flatMap((rawPage, pageIndex): DocsNavItem[] => {
      const reference = pageReference(rawPage, `Docs sidebar ${title} page ${pageIndex + 1}`)
      if (typeof reference !== "string" && "href" in reference) {
        return [{ title: reference.label, to: reference.href, external: reference.external }]
      }

      const slug = typeof reference === "string" ? reference : reference.slug
      if (referencedSlugs.has(slug)) throw new Error(`Duplicate docs sidebar page: ${slug}`)
      referencedSlugs.add(slug)
      const page = pagesBySlug.get(slug)
      if (!page) throw new Error(`Unknown docs sidebar page: ${slug}`)
      if (page.draft && !includeDrafts) return []
      orderedPages.push(page)
      return [
        {
          title: typeof reference === "string" ? page.title : reference.label ?? page.title,
          to: page.route,
          draft: page.draft || undefined,
        },
      ]
    })

    return items.length > 0 ? [{ title, items }] : []
  })

  return { groups, orderedPages }
}

export function docsPublicationOrder(rawConfigs: unknown | unknown[], pages: DocsPage[]): DocsPage[] {
  const publishedPages = pages.filter((page) => !page.draft)
  const configs = Array.isArray(rawConfigs) ? rawConfigs : [rawConfigs]
  const orderedPages: DocsPage[] = []
  const orderedSlugs = new Set<string>()

  for (const rawConfig of configs) {
    const resolved = resolveDocsSidebar(rawConfig, pages, false)
    for (const page of resolved.orderedPages) {
      if (orderedSlugs.has(page.slug)) throw new Error(`Duplicate docs publication page: ${page.slug}`)
      orderedSlugs.add(page.slug)
      orderedPages.push(page)
    }
  }

  const unlisted = publishedPages.filter((page) => !orderedSlugs.has(page.slug))
  return [...orderedPages, ...unlisted]
}
