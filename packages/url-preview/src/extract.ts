import { normalizePreviewUrl } from "./normalize.js"

const rawUrlRegex = /(?:https?:\/\/|www\.)[^\s<>"'`]+/gi

export function extractPreviewUrl(text: string, candidates: readonly string[] = []): string | null {
  return extractPreviewUrls(text, candidates, { limit: 1 })[0] ?? null
}

export function extractPreviewUrls(
  text: string,
  candidates: readonly string[] = [],
  options: { limit?: number } = {},
): string[] {
  const limit = options.limit ?? 3
  const urls: string[] = []
  const seen = new Set<string>()

  const append = (input: string) => {
    if (urls.length >= limit) {
      return
    }

    const normalized = normalizePreviewUrl(input)
    if (!normalized || seen.has(normalized)) {
      return
    }

    seen.add(normalized)
    urls.push(normalized)
  }

  for (const candidate of candidates) {
    append(candidate)
  }

  for (const match of text.matchAll(rawUrlRegex)) {
    append(match[0] ?? "")
  }

  return urls
}
