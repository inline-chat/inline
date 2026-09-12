import {
  NotImplementedError,
  stringifyMarkdown,
  type AdapterPostableMessage,
  type CardChild,
  type CardElement,
} from "chat"
import { escapeMarkdown } from "./markdown.js"
import type { BotMessageAction } from "@inline-chat/bot-api-types"

export function renderContent(message: AdapterPostableMessage) {
  if (typeof message === "string") return { text: message, parse_markdown: true }
  if ("raw" in message) return { text: message.raw, parse_markdown: false }
  if ("markdown" in message) return { text: message.markdown, parse_markdown: true }
  if ("ast" in message) return { text: stringifyMarkdown(message.ast), parse_markdown: true }
  const card: CardElement = "card" in message ? message.card : message
  const lines: string[] = [card.title, card.subtitle].filter((text): text is string => !!text).map(escapeMarkdown)
  const actions: BotMessageAction[][] = []
  const url = (value: string) => {
    if (!/^https?:\/\//i.test(value)) throw new Error("Card image and link URLs must use HTTP(S)")
    return value
      .replace(/ /g, "%20")
      .replace(/\(/g, "%28")
      .replace(/\)/g, "%29")
      .replace(/[\r\n]/g, "")
  }
  if (card.imageUrl) lines.push(`![](${url(card.imageUrl)})`)
  function visit(child: CardChild): void {
    switch (child.type) {
      case "text":
        lines.push(child.style === "bold" ? `**${child.content}**` : child.content)
        return
      case "divider":
        lines.push("---")
        return
      case "section":
        child.children.forEach(visit)
        return
      case "fields":
        child.children.forEach((field) =>
          lines.push(`**${escapeMarkdown(field.label)}**: ${escapeMarkdown(field.value)}`),
        )
        return
      case "image":
        lines.push(`![${escapeMarkdown(child.alt ?? "")}](${url(child.url)})`)
        return
      case "link":
        lines.push(`[${escapeMarkdown(child.label)}](${url(child.url)})`)
        return
      case "table": {
        const cell = (value: string) => escapeMarkdown(value).replace(/\n/g, " ")
        lines.push(
          [
            `| ${child.headers.map(cell).join(" | ")} |`,
            `| ${child.headers
              .map((_, index) =>
                child.align?.[index] === "center" ? ":---:" : child.align?.[index] === "right" ? "---:" : "---",
              )
              .join(" | ")} |`,
            ...child.rows.map((row) => `| ${row.map(cell).join(" | ")} |`),
          ].join("\n"),
        )
        return
      }
      case "actions": {
        const row: BotMessageAction[] = []
        for (const button of child.children) {
          if (button.type === "link-button") {
            lines.push(`[${escapeMarkdown(button.label)}](${url(button.url)})`)
            continue
          }
          if (button.type !== "button" || button.disabled || button.callbackUrl || button.actionType === "modal") {
            throw new NotImplementedError(
              "Inline cards support active callback buttons only; selects and modals are unsupported",
            )
          }
          row.push(
            button.value !== undefined
              ? { type: "callback", action_id: button.id, text: button.label, callback_data: button.value }
              : { type: "callback", action_id: button.id, text: button.label },
          )
        }
        if (row.length > 8) throw new Error("Inline supports at most 8 buttons per row")
        if (row.length) actions.push(row)
        return
      }
      default:
        throw new NotImplementedError(`Inline card element ${child.type} is unsupported`)
    }
  }
  card.children.forEach(visit)
  if (actions.length > 8) throw new Error("Inline supports at most 8 action rows")
  // Use the same server Markdown parser as ordinary messages; preserve callback controls.
  return { text: lines.join("\n\n"), parse_markdown: true, actions }
}
