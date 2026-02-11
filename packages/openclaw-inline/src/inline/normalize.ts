export function normalizeInlineTarget(raw: string): string | undefined {
  let normalized = raw.trim()
  if (!normalized) return undefined

  const lowered = normalized.toLowerCase()
  if (lowered.startsWith("inline:")) {
    normalized = normalized.slice("inline:".length).trim()
  }

  // Allow "chat:<id>" for readability.
  normalized = normalized.replace(/^chat:/i, "").trim()
  return normalized || undefined
}

export function looksLikeInlineTargetId(raw: string): boolean {
  const normalized = normalizeInlineTarget(raw)
  if (!normalized) return false
  return /^[0-9]+$/.test(normalized)
}

