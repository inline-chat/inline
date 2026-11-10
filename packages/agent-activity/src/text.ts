/** Detail a row shows: the end of long output, as Codex previews it. */
export const MAX_DETAIL_CHARS = 2_000
/** Diff text one edit row shows before later files list by name only. */
export const MAX_ROW_DIFF_CHARS = 8_000

/** "8s", "1m 4s", "1h 2m": the bridge's "Worked for" and the clients' live timer. */
export function elapsedText(ms: number): string {
  const seconds = Math.floor(Math.max(0, Number.isFinite(ms) ? ms : 0) / 1000)
  if (seconds < 60) return `${Math.max(1, seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

/** The first non-empty line, without Markdown bold markers, at most `max` characters. */
export function firstLine(text: string, max: number): string {
  const line = (text.split("\n").find((candidate) => candidate.trim() !== "") ?? "")
    .trim()
    .replace(/^\*+|\*+$/g, "")
    .trim()
  const characters = Array.from(line)
  return characters.length > max ? `${characters.slice(0, max).join("")}…` : line
}

/** The end of a long text from a line start, with the hidden line count ("… +120 lines"). */
export function tail(text: string, max = MAX_DETAIL_CHARS): string {
  const characters = Array.from(text)
  if (characters.length <= max) return text
  const cutText = characters.slice(characters.length - max).join("")
  const cut = text.length - cutText.length
  const newline = text.indexOf("\n", cut)
  const start = newline >= 0 && newline + 1 < text.length ? newline + 1 : cut
  const hidden = Math.max(1, text.slice(0, start).split("\n").length - (text.slice(0, start).endsWith("\n") ? 1 : 0))
  return `… +${hidden} ${hidden === 1 ? "line" : "lines"}\n${text.slice(start)}`
}

/** The start of a long text. */
export function head(text: string, max = MAX_DETAIL_CHARS): string {
  const characters = Array.from(text)
  return characters.length <= max ? text : `${characters.slice(0, max).join("")}…`
}

/** A path under `folder`, relative to it, as the harnesses show paths. */
export function relativePath(path: string, folder?: string): string {
  if (!folder) return path
  const base = folder.endsWith("/") ? folder : `${folder}/`
  return path.startsWith(base) && path.length > base.length ? path.slice(base.length) : path
}

export function baseName(path: string): string {
  const trimmed = path.replace(/\/+$/, "")
  const index = trimmed.lastIndexOf("/")
  return index >= 0 ? trimmed.slice(index + 1) || trimmed : trimmed
}

const SECRET_ASSIGNMENT = /\b([A-Za-z0-9_.-]*(?:api[_-]?key|access[_-]?key|secret|token|passw(?:or)?d|credential|auth)[A-Za-z0-9_.-]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"'&]+)/gi
const BEARER = /\b(bearer|basic)\s+[A-Za-z0-9._~+/-]{8,}=*/gi
const KNOWN_KEYS = /\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})\b/g
const URL_CREDENTIALS = /\b([a-z][a-z0-9+.-]*:\/\/)[^\s/:@]+:[^\s/@]+@/gi

/**
 * Hides values that look like credentials in commands, arguments and output
 * before they reach a chat: `TOKEN=…`, `--password …`, bearer headers,
 * well-known key prefixes and credentials inside URLs. Best effort; the
 * harness's own redaction still applies first.
 */
export function redactSecrets(text: string): string {
  return text
    .replace(BEARER, (_match, scheme: string) => `${scheme} •••`)
    .replace(SECRET_ASSIGNMENT, (match, key: string, separator: string, value: string) =>
      /^(bearer|basic)$/i.test(value) ? match : `${key}${separator}•••`)
    .replace(/(--?(?:password|passwd|token|secret|api-key|apikey)\s+)(\S+)/gi, "$1•••")
    .replace(KNOWN_KEYS, "•••")
    .replace(URL_CREDENTIALS, "$1•••@")
}
