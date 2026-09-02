import type { ExternalResourceRecord } from "./externalResources.effect"

const titleSegments = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/** Provider metadata stays server-side; the menu receives ordinary link records. */
export function rankExternalResources(
  resources: readonly ExternalResourceRecord[],
  query: string,
  limit: number,
): ExternalResourceRecord[] {
  const unique = new Map<string, ExternalResourceRecord>()
  for (const resource of resources) {
    const id = resource.provider === "notion" ? resource.id.replaceAll("-", "").toLowerCase() : resource.id
    const key = `${resource.provider}:${id}`
    const previous = unique.get(key)
    // Preserve connection precedence, but do not lose a known emoji.
    unique.set(key, previous ? { ...previous, emoji: previous.emoji || resource.emoji } : resource)
  }

  const normalizedQuery = normalize(query)
  const scored = [...unique.values()].map((resource) => ({
    resource,
    match: titleMatch(normalize(resource.title), normalizedQuery),
    structure: structureRank(resource),
    edited: Date.parse(resource.lastEditedTime ?? "") || 0,
  }))
  scored.sort((a, b) =>
    (normalizedQuery ? a.match - b.match || a.structure - b.structure : 0)
    || b.edited - a.edited
    || a.resource.id.localeCompare(b.resource.id),
  )
  return scored.slice(0, limit).map(({ resource }) => ({
    ...resource,
    title: displayTitle(resource.title),
  }))
}

function displayTitle(value: string): string {
  let title = ""
  let count = 0
  for (const { segment } of titleSegments.segment(value)) {
    if (count++ === 180) break
    title += segment
  }
  return title
}

function normalize(value: string): string {
  return value.normalize("NFKC").toLowerCase().trim().replace(/\s+/gu, " ")
}

function titleMatch(title: string, query: string): number {
  if (title === query) return 0
  if (title.startsWith(query)) return 1
  const words = title.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  if (query.split(" ").every((token) => words.some((word) => word.startsWith(token)))) return 2
  return 3
}

function structureRank(resource: ExternalResourceRecord): number {
  if (resource.kind === "database") return 0
  if (resource.parentKind === "workspace") return 1
  if (resource.parentKind === "database") return 3
  return 2
}
