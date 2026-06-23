const MAX_REPLY_CHARS = 24_000
const HEADING_RE = /^(#{1,6})[ \t]+(.+?)[ \t#]*$/
const LIST_MARKER_INDENT_RE = /^([ \t]{1,3})([-*+]|\d{1,3}[.)])\s+/

export function cleanInlineMarkdown(text: string): string {
  const trimmed = text.replace(/[ \t]+\n/g, "\n").trim()
  const normalized = normalizeBlockMarkdown(trimmed)
  const bounded = normalized.length > MAX_REPLY_CHARS ? `${normalized.slice(0, MAX_REPLY_CHARS - 32)}\n\n[truncated]` : normalized
  return closeDanglingCodeFence(bounded)
}

export function userVisibleError(code: string): string {
  switch (code) {
    case "not_connected":
      return "Connect ChatGPT in Settings > Connections to use this bot."
    case "refresh_failed":
      return "Your ChatGPT connection needs to be reconnected."
    case "disabled":
      return "ChatGPT is temporarily unavailable."
    case "canceled":
      return "Stopped."
    default:
      return "ChatGPT is unavailable right now. Try again in a bit."
  }
}

function closeDanglingCodeFence(text: string): string {
  const matches = text.match(/```/g)
  if (!matches || matches.length % 2 === 0) {
    return text
  }
  return `${text}\n\`\`\``
}

function normalizeBlockMarkdown(text: string): string {
  const lines = text.split("\n")
  let inFence = false

  return lines
    .map((line) => {
      if (isFenceBoundary(line)) {
        inFence = !inFence
        return line
      }

      if (inFence) {
        return line
      }

      const heading = line.match(HEADING_RE)
      if (heading) {
        return heading[2]?.trimEnd() ?? ""
      }

      return line.replace(LIST_MARKER_INDENT_RE, (_match, _indent: string, marker: string) => `${marker} `)
    })
    .join("\n")
}

function isFenceBoundary(line: string): boolean {
  return /^\s*(```|~~~)/.test(line)
}
