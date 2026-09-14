import { parseMarkdown, type FormattedContent } from "chat"
import type { BotMessage, BotRichBlock, BotRichText, BotMessageEntityOutput } from "@inline-chat/bot-api-types"

/** Escape literal Bot API text before reconstructing Markdown. JavaScript offsets are UTF-16. */
export function escapeMarkdown(text: string): string {
  return text.replace(/[\\`*_{}[\]<>()#+.!|~=$-]/g, "\\$&")
}
const destination = (url: string) =>
  url
    .replace(/ /g, "%20")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29")
    .replace(/[\r\n]/g, "")
function plain(text: BotRichText): string {
  return typeof text === "string" ? text : Array.isArray(text) ? text.map(plain).join("") : plain(text.text)
}
function code(text: string, block = false, language = ""): string {
  const length = Math.max(block ? 3 : 1, ...Array.from(text.matchAll(/`+/g), (match) => match[0].length + 1))
  const fence = "`".repeat(length)
  if (block) return `${fence}${language.replace(/[\r\n`]/g, "")}\n${text}\n${fence}`
  const pad =
    text.startsWith("`") || text.endsWith("`") || (text.startsWith(" ") && text.endsWith(" ") && text.trim()) ? " " : ""
  return `${fence}${pad}${text}${pad}${fence}`
}

export function richTextToMarkdown(value: BotRichText): string {
  if (typeof value === "string") return escapeMarkdown(value)
  if (Array.isArray(value)) return value.map(richTextToMarkdown).join("")
  const text = richTextToMarkdown(value.text)
  switch (value.type) {
    case "bold":
      return `**${text}**`
    case "italic":
      return `*${text}*`
    case "underline":
      return `<u>${text}</u>`
    case "strikethrough":
      return `~~${text}~~`
    case "highlight":
      return `==${text}==`
    case "code":
      return code(plain(value.text))
    case "math":
      return `$${value.latex}$`
    case "url":
      return `[${text}](${destination(value.url)})`
    case "email_address":
      return `[${text}](mailto:${destination(value.email_address)})`
    case "phone_number":
      return `[${text}](tel:${destination(value.phone_number)})`
    case "text_mention":
      return `[${text}](inline://user?id=${value.user.id})`
    case "chat_link":
      return `[[${text}]](inline://chat?id=${value.chat_id})`
    // Preserve labels for native references with no documented Markdown URL encoding.
    case "mention":
    case "bot_command":
    case "thread_title":
    case "group_mention":
      return text
  }
}

export function richBlocksToMarkdown(blocks: BotRichBlock[]): string {
  return blocks
    .map((block) => {
      switch (block.type) {
        case "paragraph":
          return richTextToMarkdown(block.text)
        case "heading":
          return `${"#".repeat(Math.min(6, Math.max(1, block.size)))} ${richTextToMarkdown(block.text)}`
        case "pre":
          return code(plain(block.text), true, block.language)
        case "math":
          return `$$\n${block.latex}\n$$`
        case "footer":
          return `<footer>${richTextToMarkdown(block.text)}</footer>`
        case "divider":
          return "---"
        case "blockquote":
          return richBlocksToMarkdown(block.blocks)
            .split("\n")
            .map((line) => `> ${line}`)
            .join("\n")
        case "collage":
          return richBlocksToMarkdown(block.blocks)
        case "details":
          return `<details${block.is_open ? " open" : ""}>\n<summary${
            block.kind === "progress" ? ' kind="progress"' : ""
          }>${richTextToMarkdown(block.summary)}</summary>\n\n${richBlocksToMarkdown(block.blocks)}\n\n</details>`
        case "list":
          return block.items
            .map((item) => {
              const marker = item.has_checkbox
                ? `- [${item.is_checked ? "x" : " "}] `
                : item.value !== undefined
                ? `${item.value}. `
                : "- "
              const lines = richBlocksToMarkdown(item.blocks).split("\n")
              return (
                marker + lines.map((line, index) => (index === 0 ? line : " ".repeat(marker.length) + line)).join("\n")
              )
            })
            .join("\n")
        case "table": {
          const first = block.cells[0]
          if (!first) return ""
          const row = (cells: typeof first) =>
            `| ${cells.map((cell) => richTextToMarkdown(cell.text).replace(/\n/g, " ")).join(" | ")} |`
          const separator = `| ${first
            .map((cell) => (cell.align === "center" ? ":---:" : cell.align === "right" ? "---:" : "---"))
            .join(" | ")} |`
          return [row(first), separator, ...block.cells.slice(1).map(row)].join("\n")
        }
        case "photo":
          return block.file?.download_url
            ? `![${richTextToMarkdown(block.alt ?? "")}](${destination(block.file.download_url)})`
            : richTextToMarkdown(block.alt ?? "[Image]")
      }
    })
    .join("\n\n")
}

/** Reconstruct semantic Inline Markdown; original source whitespace is not available after parsing. */
export function messageToMarkdown(message: BotMessage): string {
  if (message.rich_message) return richBlocksToMarkdown(message.rich_message.blocks)
  const text = message.text ?? ""
  const entities = (message.entities ?? []).filter(
    (entity) =>
      Number.isInteger(entity.offset) &&
      Number.isInteger(entity.length) &&
      entity.offset >= 0 &&
      entity.length > 0 &&
      entity.offset + entity.length <= text.length,
  )
  type Node = { entity?: BotMessageEntityOutput; children: Array<Node | string> }
  const root: Node = { children: [] }
  const stack: Node[] = [root]
  let previous: BotMessageEntityOutput[] = []
  const points = [
    ...new Set([0, text.length, ...entities.flatMap((entity) => [entity.offset, entity.offset + entity.length])]),
  ].sort((a, b) => a - b)
  for (let index = 0; index < points.length - 1; index++) {
    const start = points[index]!,
      end = points[index + 1]!
    const active = entities
      .filter((entity) => entity.offset <= start && entity.offset + entity.length >= end)
      .sort((a, b) => a.offset - b.offset || b.length - a.length)
    let common = 0
    while (common < active.length && active[common] === previous[common]) common++
    stack.length = common + 1
    for (const entity of active.slice(common)) {
      const node: Node = { entity, children: [] }
      stack.at(-1)!.children.push(node)
      stack.push(node)
    }
    stack.at(-1)!.children.push(text.slice(start, end))
    previous = active
  }
  const literal = (node: Node | string): string =>
    typeof node === "string" ? node : node.children.map(literal).join("")
  function render(node: Node | string): string {
    if (typeof node === "string") return escapeMarkdown(node)
    const content = node.children.map(render).join("")
    const entity = node.entity
    switch (entity?.type) {
      case "bold":
        return `**${content}**`
      case "italic":
        return `*${content}*`
      case "underline":
        return `<u>${content}</u>`
      case "strikethrough":
        return `~~${content}~~`
      case "highlight":
        return `==${content}==`
      case "code":
        return code(literal(node))
      case "pre":
        return `\n\n${code(literal(node), true, entity.language)}\n\n`
      case "math":
        return `$${literal(node)}$`
      case "text_link":
        return entity.url ? `[${content}](${destination(entity.url)})` : content
      case "url":
        return `[${content}](${destination(literal(node))})`
      case "email":
        return `[${content}](mailto:${destination(literal(node))})`
      case "phone_number":
        return `[${content}](tel:${destination(literal(node))})`
      case "text_mention":
        return entity.user ? `[${content}](inline://user?id=${entity.user.id})` : content
      case "thread":
        return entity.chat_id ? `[[${content}]](inline://chat?id=${entity.chat_id})` : content
      default:
        return content
    }
  }
  return render(root)
}

export function messageToFormatted(message: BotMessage): FormattedContent {
  return parseMarkdown(messageToMarkdown(message))
}
