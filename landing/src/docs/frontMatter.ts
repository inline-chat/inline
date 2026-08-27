export type DocsFrontMatter = {
  title: string
  description: string
  author?: string
  date?: string
  draft: boolean
}

export type ResolvedDocsMarkdown = {
  title: string
  description: string
  markdown: string
  frontMatter: DocsFrontMatter
}

const SUPPORTED_FIELDS = new Set(["title", "description", "author", "date", "draft"])

function nonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Docs front matter field ${field} must be a non-empty string`)
  }
  return value.trim()
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) return undefined
  return nonEmptyString(value, field)
}

function scalar(value: string, field: string): string | boolean | undefined {
  const trimmed = value.trim()
  if (!trimmed) return undefined
  if (trimmed === "true") return true
  if (trimmed === "false") return false

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
  const fields: Record<string, unknown> = {}
  for (const line of lines) {
    if (!line.trim() || line.trimStart().startsWith("#")) continue
    if (/^\s/.test(line)) throw new Error("Docs front matter supports flat fields only")

    const separator = line.indexOf(":")
    if (separator <= 0) throw new Error(`Invalid docs front matter line: ${line}`)
    const field = line.slice(0, separator).trim()
    if (!SUPPORTED_FIELDS.has(field)) throw new Error(`Unsupported docs front matter field: ${field}`)
    if (field in fields) throw new Error(`Duplicate docs front matter field: ${field}`)
    fields[field] = scalar(line.slice(separator + 1), field)
  }

  if (fields.draft !== undefined && typeof fields.draft !== "boolean") {
    throw new Error("Docs front matter field draft must be true or false")
  }

  return {
    title: nonEmptyString(fields.title, "title"),
    description: nonEmptyString(fields.description, "description"),
    author: optionalString(fields.author, "author"),
    date: optionalString(fields.date, "date"),
    draft: fields.draft ?? false,
  }
}

export function parseDocsFrontMatter(source: string): { markdown: string; frontMatter: DocsFrontMatter } {
  const lines = source.split(/\r?\n/)
  if (lines[0]?.trim() !== "---") throw new Error("Docs pages require front matter starting with ---")

  const closingIndex = lines.findIndex((line, index) => index > 0 && line.trim() === "---")
  if (closingIndex < 0) throw new Error("Docs front matter is missing its closing ---")

  return {
    markdown: lines
      .slice(closingIndex + 1)
      .join("\n")
      .replace(/^\n/, ""),
    frontMatter: parseFields(lines.slice(1, closingIndex)),
  }
}

function applyTitle(markdown: string, title: string): string {
  const h1 = /^#\s+.+(?:\n|$)/m
  if (h1.test(markdown)) return markdown.replace(h1, `# ${title}\n`)
  return `# ${title}\n\n${markdown}`
}

export function resolveDocsMarkdown(source: string): ResolvedDocsMarkdown {
  const { markdown, frontMatter } = parseDocsFrontMatter(source)
  return {
    title: frontMatter.title,
    description: frontMatter.description,
    markdown: applyTitle(markdown, frontMatter.title),
    frontMatter,
  }
}

export function serializeDocsFrontMatter(frontMatter: DocsFrontMatter): string {
  const lines = [
    `title: ${JSON.stringify(frontMatter.title)}`,
    `description: ${JSON.stringify(frontMatter.description)}`,
  ]
  if (frontMatter.author) lines.push(`author: ${JSON.stringify(frontMatter.author)}`)
  if (frontMatter.date) lines.push(`date: ${JSON.stringify(frontMatter.date)}`)
  if (frontMatter.draft) lines.push("draft: true")
  return ["---", ...lines, "---"].join("\n")
}
