export function cleanField(value: string | undefined | null, maxLength: number): string | null {
  const cleaned = value?.replace(/\s+/g, " ").trim()
  if (!cleaned) {
    return null
  }
  if (cleaned.length <= maxLength) {
    return cleaned
  }
  return `${cleaned.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`
}

export function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

export function asFiniteNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null
  }
  return value
}

export function stripTags(input: string | undefined): string | undefined {
  return input?.replace(/<[^>]*>/g, "")
}

export function hostLabel(url: string): string | undefined {
  try {
    const host = new URL(url).hostname.replace(/^www\./i, "")
    return host || undefined
  } catch {
    return undefined
  }
}
