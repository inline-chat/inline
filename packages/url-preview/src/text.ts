import { decodeHTML } from "entities"

export function cleanField(value: string | undefined | null, maxLength: number): string | null {
  const cleaned = stripUnsafeControls(decodeEntities(value ?? "")).replace(/\s+/g, " ").trim()
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

function decodeEntities(value: string): string {
  if (!value.includes("&")) {
    return value
  }
  return decodeHTML(value)
}

function stripUnsafeControls(value: string): string {
  let cleaned = ""
  for (const char of value) {
    const code = char.charCodeAt(0)
    if (code === 0x7f || (code < 0x20 && code !== 0x09 && code !== 0x0a && code !== 0x0d)) {
      continue
    }
    cleaned += char
  }
  return cleaned
}
