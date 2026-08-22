export type DocsFrontMatter = {
  title?: string
  author?: string
  date?: string
}

export type ResolvedDocsMarkdown = {
  title: string
  markdown: string
  frontMatter: DocsFrontMatter
}

const SUPPORTED_FIELDS = new Set<keyof DocsFrontMatter>(["title", "author", "date"])

function scalar(value: string, field: string): string | undefined {
  const trimmed = value.trim()
  if (!trimmed) return undefined

  if (trimmed.startsWith('"') || trimmed.endsWith('"')) {
    if (!(trimmed.startsWith('"') && trimmed.endsWith('"'))) {
      throw new Error(`Invalid quoted docs front matter value for ${field}`)
    }

    try {
      const parsed: unknown = JSON.parse(trimmed)
      if (typeof parsed !== "string") throw new Error()
      return parsed
    } catch {
      throw new Error(`Invalid quoted docs front matter value for ${field}`)
    }
  }

  if (trimmed.startsWith("'") || trimmed.endsWith("'")) {
    if (!(trimmed.startsWith("'") && trimmed.endsWith("'"))) {
      throw new Error(`Invalid quoted docs front matter value for ${field}`)
    }
    return trimmed.slice(1, -1).replace(/''/g, "'")
  }

  return trimmed
}

function parseFields(lines: string[]): DocsFrontMatter {
  const frontMatter: DocsFrontMatter = {}

  for (const line of lines) {
    if (!line.trim() || line.trimStart().startsWith("#")) continue

    const separator = line.indexOf(":")
    if (separator <= 0) throw new Error(`Invalid docs front matter line: ${line}`)

    const field = line.slice(0, separator).trim()
    if (!SUPPORTED_FIELDS.has(field as keyof DocsFrontMatter)) {
      throw new Error(`Unsupported docs front matter field: ${field}`)
    }
    if (field in frontMatter) throw new Error(`Duplicate docs front matter field: ${field}`)

    const value = scalar(line.slice(separator + 1), field)
    if (value === undefined) continue

    if (field === "title") frontMatter.title = value
    else if (field === "author") frontMatter.author = value
    else frontMatter.date = value
  }

  return frontMatter
}

export function parseDocsFrontMatter(source: string): { markdown: string; frontMatter: DocsFrontMatter } {
  const lines = source.split(/\r?\n/)
  if (lines[0]?.trim() !== "---") return { markdown: source, frontMatter: {} }

  const closingIndex = lines.findIndex((line, index) => index > 0 && line.trim() === "---")
  if (closingIndex < 0) throw new Error("Docs front matter is missing its closing ---")

  const markdown = lines
    .slice(closingIndex + 1)
    .join("\n")
    .replace(/^\n/, "")

  return {
    markdown,
    frontMatter: parseFields(lines.slice(1, closingIndex)),
  }
}

function applyTitle(markdown: string, title: string): string {
  const h1 = /^#\s+.+(?:\n|$)/m
  if (h1.test(markdown)) return markdown.replace(h1, `# ${title}\n`)
  return `# ${title}\n\n${markdown}`
}

export function resolveDocsMarkdown(source: string, fallbackTitle: string): ResolvedDocsMarkdown {
  const { markdown, frontMatter } = parseDocsFrontMatter(source)
  const title = frontMatter.title ?? fallbackTitle

  return {
    title,
    markdown: frontMatter.title ? applyTitle(markdown, title) : markdown,
    frontMatter,
  }
}

export function serializeDocsFrontMatter(frontMatter: DocsFrontMatter): string {
  const lines: string[] = []
  if (frontMatter.title) lines.push(`title: ${JSON.stringify(frontMatter.title)}`)
  if (frontMatter.author) lines.push(`author: ${JSON.stringify(frontMatter.author)}`)
  if (frontMatter.date) lines.push(`date: ${JSON.stringify(frontMatter.date)}`)
  return lines.length > 0 ? ["---", ...lines, "---"].join("\n") : ""
}
