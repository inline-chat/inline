export function normalizeInlineTarget(raw: string): string | undefined {
  let normalized = raw.trim()
  if (!normalized) return undefined

  const lowered = normalized.toLowerCase()
  if (lowered.startsWith("inline:")) {
    normalized = normalized.slice("inline:".length).trim()
  }

  const userMatch = normalized.match(/^user:\s*([0-9]+)\s*$/i)
  if (userMatch?.[1]) {
    return `user:${userMatch[1]}`
  }

  // Allow "chat:<id>" for readability.
  normalized = normalized.replace(/^chat:/i, "").trim()
  return normalized || undefined
}

export function looksLikeInlineTargetId(raw: string, normalizedInput?: string): boolean {
  const normalized = normalizedInput?.trim() || normalizeInlineTarget(raw)
  if (!normalized) return false
  if (/^user:[0-9]+$/i.test(normalized)) return true
  return /^[0-9]+$/.test(normalized)
}
