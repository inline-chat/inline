/**
 * Builds the rich block tree from a message row, by the Mac's rules
 * (`InlineMac/Views/Message/RichContent/RichBlockLayoutPlanner*.swift`,
 * `InlineKit/RichContent/BlockContentSpan.swift`).
 *
 * - The whole message falls back to its flat text (`buildBlockTree` returns
 *   undefined) when it has no blocks, nesting deeper than 16, more than 1024
 *   blocks, or more than 256 table cells.
 * - A single block that cannot be drawn (a required range missing or out of
 *   the text, counts out of bounds) becomes a `fallback` node with the text
 *   it covers, trimmed.
 * - An unknown kind covers the gap between its nearest siblings that cover
 *   text, within its container; a run of unknown kinds shows that text once.
 * - Text inside blocks reuses the text render model for its range, with the
 *   message's entities clipped to it. Code, math, diff text and monospace
 *   values are literal.
 * - Agent cards draw the message's buttons named by `actionIds`; the tree
 *   reports them as claimed so the button rows leave them out. A card inside
 *   a closed disclosure does not claim.
 *
 * Pure and total: never throws.
 */

import type { BlockImageInfo, ContentBlock, DecisionState, MessageRow, PeerRef, TextRange } from "@inline/core-protocol"
import { buttonsById, type ButtonModel } from "../attachments/buttons"
import type { Direction } from "../direction"
import type { SafeLinkOptions } from "../links"
import { albumLayout, richImageBox, type Box } from "../media/layout"
import { strippedJpeg } from "../media/stripped"
import { bestPhotoSize } from "../media/variants"
import type { TextRenderOptions } from "../text/build"
import { normalizeHighlightRanges } from "../text/highlight"
import type { FindSpan, HighlightRange } from "../text/types"
import { clipFind, rangeSpan, richText as buildRichText, trimSpan, unionSpan, type Span } from "./text"
import type {
  BlockTree,
  DecisionCard,
  DiffLine,
  FormFieldInput,
  FormFieldNode,
  ImageNode,
  ListItem,
  RichBlock,
  RichText,
} from "./types"

export const blockLimits = {
  maxDepth: 16,
  maxBlocks: 1024,
  maxTableCells: 256,
  maxListItems: 1024,
  maxOrdinal: 999_999_999,
  maxAlbumImages: 10,
  maxFields: 128,
  maxSteps: 256,
  maxFormFields: 32,
  maxSelectOptions: 64,
  menuAfterOptions: 6,
  maxDiffLines: 400,
  maxReviewFindings: 200,
  maxPrompts: 8,
  widgetDefaultHeight: 240,
  widgetMinHeight: 80,
  widgetMaxHeight: 2000,
  widgetMaxInlineHeight: 720,
  planCollapseLines: 12,
} as const

export type BlockTreeOptions = {
  /** Text rendering options (phone links, app origins), as for `buildTextDocument`. */
  readonly text?: TextRenderOptions
  /** Link options for buttons. */
  readonly links?: SafeLinkOptions
  /** Width for image boxes (default 420). */
  readonly availableWidth?: number
  /** Current time in seconds; when given, open task suggestions past `expiresAt` read as expired. */
  readonly now?: number
  /** Disclosures the user opened or closed, by key; overrides `initiallyOpen` for button claims. */
  readonly openDisclosures?: ReadonlyMap<string, boolean>
  /**
   * Find-in-chat matches, UTF-16 `[start, end)` into the message text. Applied to every
   * block whose text comes from a range (and to code blocks); not to math, diff lines or
   * monospace values, which stay literal.
   */
  readonly highlightRanges?: readonly HighlightRange[]
}

type Input = Pick<MessageRow, "text" | "entities" | "blocks" | "actions" | "date">

type Context = {
  readonly text: string
  readonly entities: readonly unknown[] | undefined
  readonly row: Input
  readonly options: BlockTreeOptions
  readonly claimed: string[]
  /** Normalized highlight spans on the whole text. */
  readonly find: readonly FindSpan[]
  widgetSeen: boolean
}

/** Shape checks over the whole projection: depth, block count, table cells. */
const structureFits = (blocks: readonly ContentBlock[]): boolean => {
  let count = 0
  let cells = 0
  const visit = (list: readonly ContentBlock[], depth: number): boolean => {
    if (depth > blockLimits.maxDepth) return false
    for (const block of list) {
      count += 1
      if (count > blockLimits.maxBlocks) return false
      if (block.kind === "table") for (const row of block.rows) cells += row.length
      if (cells > blockLimits.maxTableCells) return false
      for (const children of childLists(block)) if (!visit(children, depth + 1)) return false
    }
    return true
  }
  return visit(blocks, 1)
}

const childLists = (block: ContentBlock): readonly (readonly ContentBlock[])[] => {
  switch (block.kind) {
    case "list":
      return block.items.map((item) => item.children)
    case "disclosure":
    case "quote":
    case "callout":
    case "planProposal":
    case "approval":
      return [block.children]
    default:
      return []
  }
}

/** Every range a block (and its children) points at. */
const rangesOf = (block: ContentBlock): (TextRange | undefined)[] => {
  const own: (TextRange | undefined)[] = []
  const images = (list: readonly BlockImageInfo[]) => list.map((image) => image.alt)
  switch (block.kind) {
    case "paragraph":
    case "heading":
    case "code":
    case "footer":
    case "math":
      own.push(block.text)
      break
    case "image":
      own.push(block.image.alt)
      break
    case "album":
      own.push(...images(block.images))
      break
    case "disclosure":
      own.push(block.summary, block.meta)
      break
    case "table":
      for (const row of block.rows) own.push(...row)
      break
    case "diff":
      own.push(block.path, block.text, block.previousPath)
      break
    case "fields":
      for (const field of block.fields) own.push(field.label, field.value)
      break
    case "steps":
      for (const step of block.steps) own.push(step.text, step.detail)
      break
    case "callout":
      own.push(block.title)
      break
    case "meter":
      own.push(block.label, block.meta)
      break
    case "form":
      own.push(block.title)
      for (const field of block.fields) {
        own.push(field.label, field.description, field.header)
        if (field.input.kind === "select") {
          for (const option of field.input.options) own.push(option.label, option.description, option.preview)
        }
      }
      break
    case "widget":
      own.push(block.title, ...images(block.images))
      break
    case "planProposal":
      own.push(block.title)
      break
    case "approval":
      own.push(block.title, block.command, block.cwd, block.reason)
      break
    case "review":
      own.push(block.title, block.summary)
      for (const finding of block.findings) own.push(finding.title, finding.body, finding.path)
      break
    case "taskSuggestion":
      own.push(block.title, block.brief)
      break
    case "nextStep":
      own.push(block.recap, block.question)
      break
    case "promptSuggestions":
      for (const prompt of block.prompts) own.push(prompt.label)
      break
    default:
      break
  }
  for (const children of childLists(block)) for (const child of children) own.push(...rangesOf(child))
  return own
}

/** The text span a block covers: the union of its valid ranges. */
const blockSpan = (text: string, block: ContentBlock): Span | undefined => {
  let span: Span | undefined
  for (const range of rangesOf(block)) {
    const valid = rangeSpan(text, range)
    if (valid && valid.end > valid.start) span = unionSpan(span, valid)
  }
  return span
}

/** End of a container's own header ranges (title, summary): its children's text starts after it. */
const headerEnd = (text: string, block: ContentBlock): number | undefined => {
  const header =
    block.kind === "disclosure"
      ? [block.summary, block.meta]
      : block.kind === "callout" || block.kind === "planProposal"
        ? [block.title]
        : block.kind === "approval"
          ? [block.title, block.command, block.cwd, block.reason]
          : []
  let end: number | undefined
  for (const range of header) {
    const span = rangeSpan(text, range)
    if (span) end = Math.max(end ?? 0, span.end)
  }
  return end
}

const dirOf = (rtl: boolean | undefined): Direction | undefined => (rtl === true ? "rtl" : rtl === false ? "ltr" : undefined)

const languagePattern = /^[A-Za-z0-9_+#.-]{1,32}$/

// ---------------------------------------------------------------------------
// The builder

/** Thrown inside a block's builder to make it fall back; caught per block. */
class Fallback extends Error {}

const fail = (): never => {
  throw new Fallback()
}

const need = <T>(value: T | undefined): T => (value === undefined ? fail() : value)

const buildList = (ctx: Context, blocks: readonly ContentBlock[], path: string, slot: Span, depth: number): RichBlock[] => {
  const spans = blocks.map((block) => blockSpan(ctx.text, block))
  const result: RichBlock[] = []
  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index]
    if (!block) continue
    const key = `${path}${index}`
    // This block's slot: from the previous covering sibling's end to the next one's start.
    let lo = slot.start
    for (let before = index - 1; before >= 0; before -= 1) {
      const span = spans[before]
      if (span) {
        lo = Math.max(lo, span.end)
        break
      }
    }
    let hi = slot.end
    for (let after = index + 1; after < blocks.length; after += 1) {
      const span = spans[after]
      if (span) {
        hi = Math.min(hi, span.start)
        break
      }
    }
    const blockSlot = { start: lo, end: Math.max(lo, hi) }
    if (block.kind === "unknown") {
      // A run of unknown kinds shows its gap once, on the first.
      const previous = blocks[index - 1]
      if (previous?.kind === "unknown") continue
      const fallback = fallbackNode(ctx, `fallback@${key}`, spans[index] ?? blockSlot)
      if (fallback) result.push(fallback)
      continue
    }
    const claimedBefore = ctx.claimed.length
    const widgetBefore = ctx.widgetSeen
    try {
      result.push(buildBlock(ctx, block, key, blockSlot, depth))
    } catch {
      // `Fallback`, or a builder bug: either way this block shows its text.
      ctx.claimed.length = claimedBefore
      ctx.widgetSeen = widgetBefore
      const fallback = fallbackNode(ctx, `fallback@${key}`, spans[index] ?? blockSlot)
      if (fallback) result.push(fallback)
    }
  }
  return result
}

const fallbackNode = (ctx: Context, key: string, span: Span): RichBlock | undefined => {
  const trimmed = trimSpan(ctx.text, span)
  if (!trimmed) return undefined
  return { kind: "fallback", key, start: trimmed.start, end: trimmed.end, text: rich(ctx, trimmed) }
}

const rich = (ctx: Context, span: Span): RichText => buildRichText(ctx.text, ctx.entities, span, ctx.options.text, ctx.find)

const richRange = (ctx: Context, range: TextRange | undefined): RichText | undefined => {
  const span = rangeSpan(ctx.text, range)
  return span ? rich(ctx, span) : undefined
}

const requiredRich = (ctx: Context, range: TextRange | undefined, nonEmpty = false): RichText => {
  const span = need(rangeSpan(ctx.text, range))
  if (nonEmpty && span.end <= span.start) fail()
  return rich(ctx, span)
}

const plain = (ctx: Context, range: TextRange | undefined): string | undefined => {
  const span = rangeSpan(ctx.text, range)
  return span ? ctx.text.slice(span.start, span.end) : undefined
}

const plainText = (text: RichText): string => text.document.text

const imageNode = (ctx: Context, image: BlockImageInfo, key: string, box?: Box): ImageNode => {
  const photo = image.state === "ready" ? image.photo : undefined
  const best = bestPhotoSize(photo)
  const dimensions =
    best && best.width > 0 && best.height > 0
      ? { width: best.width, height: best.height }
      : image.width && image.height
        ? { width: image.width, height: image.height }
        : undefined
  const alt = plain(ctx, image.alt)?.trim()
  return {
    key,
    state: image.state === "ready" && photo ? "ready" : image.state === "pending" ? "pending" : "unavailable",
    box: box ?? richImageBox(dimensions, ctx.options.availableWidth),
    alt: alt && alt.length > 0 ? alt : undefined,
    photo,
    preview: strippedJpeg(photo?.stripped ?? image.stripped),
  }
}

const imageDimensions = (image: BlockImageInfo): Box | undefined => {
  const best = image.state === "ready" ? bestPhotoSize(image.photo) : undefined
  if (best && best.width > 0 && best.height > 0) return { width: best.width, height: best.height }
  return image.width && image.height ? { width: image.width, height: image.height } : undefined
}

const chips = {
  planProposal: { pending: "Awaiting approval", accepted: "Approved", declined: "Kept planning", expired: "Expired", superseded: "Replaced" },
  approval: { pending: "Needs approval", accepted: "Approved", declined: "Denied", expired: "Expired", superseded: "Replaced" },
  taskSuggestion: { pending: undefined, accepted: "Started", declined: "Dismissed", expired: "Expired", superseded: "Replaced" },
} as const

const decisionCard = (
  ctx: Context,
  kind: keyof typeof chips,
  state: DecisionState | undefined,
  actionIds: readonly string[],
  claims: boolean,
): DecisionCard => {
  const open = state === undefined || state === "pending"
  const buttons: readonly ButtonModel[] = open ? buttonsById(ctx.row.actions, actionIds, ctx.options.links) : []
  if (claims) for (const button of buttons) if (!ctx.claimed.includes(button.actionId)) ctx.claimed.push(button.actionId)
  const chip = state ? chips[kind][state] : undefined
  const note = open ? undefined : state === "superseded" ? "Replaced by a newer request" : chip
  return { state, chip, note, buttons, showButtons: open && buttons.length > 0 }
}

const formField = (ctx: Context, field: Extract<ContentBlock, { kind: "form" }>["fields"][number], key: string): FormFieldNode => {
  if (field.fieldId.length === 0) fail()
  const label = requiredRich(ctx, field.label)
  const input = field.input
  let built: FormFieldInput
  switch (input.kind) {
    case "select": {
      if (input.options.length < 1 || input.options.length > blockLimits.maxSelectOptions) fail()
      const ids = new Set<string>()
      const options = input.options.map((option, index) => {
        if (option.optionId.length === 0 || ids.has(option.optionId)) fail()
        ids.add(option.optionId)
        return {
          key: `${key}.o${index}`,
          optionId: option.optionId,
          label: requiredRich(ctx, option.label),
          description: richRange(ctx, option.description),
          preview: plain(ctx, option.preview),
          recommended: option.recommended,
        }
      })
      const defaults = input.defaultOptionIds.filter((id) => ids.has(id))
      built = {
        kind: "select",
        options,
        multiple: input.multiple,
        presentation: !input.multiple && options.length > blockLimits.menuAfterOptions ? "menu" : "list",
        defaultOptionIds: input.multiple ? [...new Set(defaults)] : defaults.slice(0, 1),
        allowOther: input.allowOther,
      }
      break
    }
    case "text":
      built = {
        kind: "text",
        style: input.style,
        placeholder: input.placeholder,
        defaultValue: input.style === "secret" ? undefined : input.defaultValue,
        maxLength: input.maxLength !== undefined && input.maxLength > 0 ? input.maxLength : undefined,
      }
      break
    case "toggle":
      built = { kind: "toggle", defaultValue: input.defaultValue }
      break
    case "number":
      built = {
        kind: "number",
        defaultValue: input.defaultValue,
        min: input.min,
        max: input.max,
        step: input.step !== undefined && input.step > 0 ? input.step : 1,
        integer: input.integer,
      }
      break
    case "unknown":
      return fail()
  }
  return {
    key,
    fieldId: field.fieldId,
    label,
    labelText: plainText(label).trim(),
    header: richRange(ctx, field.header),
    description: richRange(ctx, field.description),
    required: field.required,
    input: built,
  }
}

const diffLines = (text: string | undefined, key: string): { lines: DiffLine[]; hidden: number } => {
  if (text === undefined || text.length === 0) return { lines: [], hidden: 0 }
  const all = text.replace(/\n$/, "").split("\n")
  const lines = all.slice(0, blockLimits.maxDiffLines).map((line, index): DiffLine => {
    const kind = line.startsWith("@@") ? "hunk" : line.startsWith("+") ? "add" : line.startsWith("-") ? "delete" : "context"
    return { key: `${key}.l${index}`, kind, text: line }
  })
  return { lines, hidden: Math.max(0, all.length - lines.length) }
}

const isOpen = (ctx: Context, key: string, initiallyOpen: boolean): boolean => ctx.options.openDisclosures?.get(key) ?? initiallyOpen

const buildBlock = (ctx: Context, block: ContentBlock, path: string, slot: Span, depth: number, claims = true): RichBlock => {
  const key = `${block.kind}@${path}`
  const span = blockSpan(ctx.text, block) ?? { start: 0, end: 0 }
  const base = { key, start: span.start, end: span.end }
  const childSlot = (end?: number): Span => ({ start: Math.max(slot.start, end ?? slot.start), end: slot.end })
  const children = (list: readonly ContentBlock[], claimChildren = claims) =>
    buildChildren(ctx, list, `${path}.`, childSlot(headerEnd(ctx.text, block)), depth + 1, claimChildren)

  switch (block.kind) {
    case "paragraph":
      return { ...base, kind: "paragraph", text: requiredRich(ctx, block.text) }
    case "footer":
      return { ...base, kind: "footer", text: requiredRich(ctx, block.text) }
    case "heading": {
      const level = Math.min(6, Math.max(1, Math.trunc(block.level) || 1)) as 1 | 2 | 3 | 4 | 5 | 6
      return { ...base, kind: "heading", level, text: requiredRich(ctx, block.text) }
    }
    case "math": {
      const source = need(plain(ctx, block.text))
      if (source.length === 0) fail()
      return { ...base, kind: "math", source }
    }
    case "code": {
      const codeSpan = need(rangeSpan(ctx.text, block.text))
      const find = clipFind(ctx.find, codeSpan)
      return {
        ...base,
        kind: "code",
        language: block.language && languagePattern.test(block.language) ? block.language : undefined,
        code: ctx.text.slice(codeSpan.start, codeSpan.end),
        ...(find.length > 0 ? { find } : {}),
      }
    }
    case "separator":
      return { ...base, kind: "separator" }
    case "list": {
      if (!block.style || block.items.length < 1 || block.items.length > blockLimits.maxListItems) fail()
      const ordered = block.style === "ordered"
      const first = ordered ? (block.start ?? 1) : 1
      if (first < 0 || first > blockLimits.maxOrdinal) fail()
      const items: ListItem[] = block.items.map((item, index) => {
        const marker =
          item.checked !== undefined
            ? ({ kind: "task", checked: item.checked } as const)
            : ordered
              ? ({ kind: "number", value: first + index } as const)
              : ({ kind: "bullet" } as const)
        return {
          key: `item@${path}.${index}`,
          marker,
          markerText: marker.kind === "task" ? (marker.checked ? "☑" : "☐") : marker.kind === "number" ? `${marker.value}.` : "•",
          children: buildChildren(ctx, item.children, `${path}.${index}.`, slot, depth + 1, claims),
        }
      })
      return { ...base, kind: "list", ordered, dir: dirOf(block.rtl), items }
    }
    case "image":
      return { ...base, kind: "image", image: imageNode(ctx, block.image, `${key}.i`) }
    case "album": {
      const layout = need(albumLayout(block.images.map(imageDimensions)))
      const images = block.images.map((image, index) => {
        const item = layout.items[index]
        return imageNode(ctx, image, `${key}.i${index}`, item ? { width: item.width, height: item.height } : undefined)
      })
      return { ...base, kind: "album", images, layout }
    }
    case "disclosure": {
      const summary = requiredRich(ctx, block.summary)
      const initiallyOpen = block.initiallyOpen === true
      const open = isOpen(ctx, key, initiallyOpen)
      const progress = block.style === "progress"
      return {
        ...base,
        kind: "disclosure",
        summary,
        style: block.style,
        initiallyOpen,
        open,
        activity: block.activity === "agent" ? undefined : block.activity,
        status: block.status,
        statusBadge:
          block.status === "waiting" || block.status === "failed" || block.status === "cancelled" ? block.status : undefined,
        shimmer: progress || block.status === "running",
        meta: richRange(ctx, block.meta),
        timer: progress ? { startedAt: block.startedAt ?? ctx.row.date } : undefined,
        dir: dirOf(block.rtl),
        children: children(block.children, claims && open),
      }
    }
    case "quote":
      if (block.children.length === 0) fail()
      return { ...base, kind: "quote", dir: dirOf(block.rtl), children: children(block.children) }
    case "table": {
      const columns = block.rows[0]?.length ?? 0
      if (columns < 1 || block.rows.length > Math.floor(blockLimits.maxTableCells / columns)) fail()
      const rows = block.rows.map((row, rowIndex) => {
        if (row.length !== columns) fail()
        return row.map((cell, column) => ({ key: `${key}.r${rowIndex}c${column}`, text: requiredRich(ctx, cell) }))
      })
      const alignments = Array.from({ length: columns }, (_, column) => block.alignments[column] ?? ("start" as const))
      return { ...base, kind: "table", dir: dirOf(block.rtl), alignments, header: rows[0] ?? [], rows: rows.slice(1) }
    }
    case "diff": {
      const path = need(plain(ctx, block.path))
      const { lines, hidden } = diffLines(plain(ctx, block.text), key)
      return {
        ...base,
        kind: "diff",
        path,
        previousPath: plain(ctx, block.previousPath),
        change: block.change === "added" || block.change === "deleted" || block.change === "renamed" ? block.change : "modified",
        additions: block.additions,
        deletions: block.deletions,
        language: block.language && languagePattern.test(block.language) ? block.language : undefined,
        lines,
        hiddenLines: hidden,
        footer: hidden > 0 ? `${hidden} more lines` : block.truncated ? "Diff shortened by the agent" : undefined,
      }
    }
    case "fields": {
      if (block.fields.length < 1 || block.fields.length > blockLimits.maxFields) fail()
      return {
        ...base,
        kind: "fields",
        dir: dirOf(block.rtl),
        fields: block.fields.map((field, index) => ({
          key: `${key}.f${index}`,
          label: requiredRich(ctx, field.label),
          value: field.monospace ? undefined : requiredRich(ctx, field.value),
          code: field.monospace ? need(plain(ctx, field.value)) : undefined,
        })),
      }
    }
    case "steps":
      if (block.steps.length < 1 || block.steps.length > blockLimits.maxSteps) fail()
      return {
        ...base,
        kind: "steps",
        dir: dirOf(block.rtl),
        card: depth === 0,
        steps: block.steps.map((step, index) => ({
          key: `${key}.s${index}`,
          text: requiredRich(ctx, step.text),
          status: step.status,
          detail: richRange(ctx, step.detail),
        })),
      }
    case "callout":
      return {
        ...base,
        kind: "callout",
        tone: block.tone ?? "info",
        title: richRange(ctx, block.title),
        dir: dirOf(block.rtl),
        children: children(block.children),
      }
    case "meter": {
      if (!(Number.isFinite(block.max) && block.max > 0 && Number.isFinite(block.value))) fail()
      return {
        ...base,
        kind: "meter",
        label: requiredRich(ctx, block.label),
        value: block.value,
        max: block.max,
        fraction: Math.min(1, Math.max(0, block.value / block.max)),
        meta: richRange(ctx, block.meta),
        tone: block.tone ?? "normal",
      }
    }
    case "form": {
      if (block.formId.length === 0 || block.fields.length > blockLimits.maxFormFields) fail()
      const ids = new Set<string>()
      const fields = block.fields.map((field, index) => {
        if (ids.has(field.fieldId)) fail()
        ids.add(field.fieldId)
        return formField(ctx, field, `${key}.f${index}`)
      })
      return {
        ...base,
        kind: "form",
        formId: block.formId,
        title: richRange(ctx, block.title),
        dir: dirOf(block.rtl),
        fields,
        submitLabel: block.submitLabel?.trim() || "Submit",
        requiredGrant: block.requiredGrant,
        closed: block.closed,
      }
    }
    case "widget": {
      // At most one live widget per message: later ones show their text.
      if (ctx.widgetSeen || block.widgetId.length === 0 || block.htmlLength === 0) fail()
      const title = requiredRich(ctx, block.title, true)
      ctx.widgetSeen = true
      const hint = block.height ?? blockLimits.widgetDefaultHeight
      return {
        ...base,
        kind: "widget",
        widgetId: block.widgetId,
        title,
        frame: { kind: "sandboxedFrame", origin: "separate", network: "none" },
        height: Math.min(blockLimits.widgetMaxHeight, Math.max(blockLimits.widgetMinHeight, hint)),
        maxInlineHeight: blockLimits.widgetMaxInlineHeight,
        images: block.images.map((image, index) => imageNode(ctx, image, `${key}.i${index}`)),
        requiredGrant: block.requiredGrant,
      }
    }
    case "planProposal": {
      const title = block.title ? requiredRich(ctx, block.title, true) : undefined
      return {
        ...base,
        kind: "planProposal",
        ...decisionCard(ctx, "planProposal", block.state, block.actionIds, claims),
        title,
        defaultTitle: "Plan",
        dir: dirOf(block.rtl),
        children: children(block.children),
        decidedByUserId: block.decidedByUserId,
        collapseAfterLines: blockLimits.planCollapseLines,
      }
    }
    case "approval": {
      const title = block.title ? requiredRich(ctx, block.title, true) : undefined
      return {
        ...base,
        kind: "approval",
        ...decisionCard(ctx, "approval", block.state, block.actionIds, claims),
        subject: block.subject,
        title,
        defaultTitle: "Approval",
        command: plain(ctx, block.command),
        cwd: plain(ctx, block.cwd),
        reason: richRange(ctx, block.reason),
        dir: dirOf(block.rtl),
        children: children(block.children),
        decidedByUserId: block.decidedByUserId,
      }
    }
    case "review": {
      if (block.findings.length > blockLimits.maxReviewFindings) fail()
      const findings = block.findings.map((finding, index) => {
        const button = finding.actionId ? buttonsById(ctx.row.actions, [finding.actionId], ctx.options.links)[0] : undefined
        if (button && claims && !ctx.claimed.includes(button.actionId)) ctx.claimed.push(button.actionId)
        const start = finding.startLine
        const end = finding.endLine
        return {
          key: `${key}.f${index}`,
          title: requiredRich(ctx, finding.title, true),
          body: richRange(ctx, finding.body),
          priority: finding.priority,
          priorityLabel: finding.priority?.toUpperCase(),
          path: plain(ctx, finding.path),
          lines: start !== undefined ? (end !== undefined && end > start ? `${start}-${end}` : `${start}`) : undefined,
          category: finding.category,
          confidence: finding.confidence,
          outcome: finding.outcome,
          button,
        }
      })
      const count = findings.length
      return {
        ...base,
        kind: "review",
        title: block.title ? requiredRich(ctx, block.title, true) : undefined,
        defaultTitle: "Review",
        verdict: block.verdict,
        chip:
          count === 0 ? (block.verdict === "correct" ? "Looks good" : "No findings") : count === 1 ? "1 finding" : `${count} findings`,
        summary: richRange(ctx, block.summary),
        dir: dirOf(block.rtl),
        findings,
      }
    }
    case "taskSuggestion": {
      const title = requiredRich(ctx, block.title, true)
      const open = block.state === undefined || block.state === "pending"
      const now = ctx.options.now
      const expired = open && now !== undefined && block.expiresAt !== undefined && now > block.expiresAt
      const state: DecisionState | undefined = expired ? "expired" : block.state
      const openThread: PeerRef | undefined = state === "accepted" ? block.startedPeer : undefined
      return {
        ...base,
        kind: "taskSuggestion",
        ...decisionCard(ctx, "taskSuggestion", state, block.actionIds, claims),
        title,
        brief: richRange(ctx, block.brief),
        dir: dirOf(block.rtl),
        openThread,
      }
    }
    case "nextStep": {
      const buttons = buttonsById(ctx.row.actions, block.actionIds, ctx.options.links)
      if (claims) for (const button of buttons) if (!ctx.claimed.includes(button.actionId)) ctx.claimed.push(button.actionId)
      return {
        ...base,
        kind: "nextStep",
        recap: requiredRich(ctx, block.recap, true),
        question: richRange(ctx, block.question),
        dir: dirOf(block.rtl),
        buttons,
        blocking: block.blocking,
        chip: block.blocking ? "Waiting on you" : undefined,
      }
    }
    case "promptSuggestions": {
      if (block.prompts.length < 1 || block.prompts.length > blockLimits.maxPrompts) fail()
      return {
        ...base,
        kind: "promptSuggestions",
        dir: dirOf(block.rtl),
        prompts: block.prompts.map((prompt, index) => {
          const label = requiredRich(ctx, prompt.label, true)
          const composeText = (prompt.text ?? plainText(label)).trim()
          if (composeText.length === 0) fail()
          return { key: `${key}.p${index}`, label, composeText }
        }),
      }
    }
    case "unknown":
      return fail()
  }
}

const buildChildren = (
  ctx: Context,
  blocks: readonly ContentBlock[],
  path: string,
  slot: Span,
  depth: number,
  claims: boolean,
): RichBlock[] => {
  if (claims) return buildList(ctx, blocks, path, slot, depth)
  // Children that are not drawn (a closed disclosure) do not claim buttons.
  const before = ctx.claimed.length
  const result = buildList(ctx, blocks, path, slot, depth)
  ctx.claimed.length = before
  return result
}

/**
 * The block tree for a message, or undefined when it should render as flat
 * text (no blocks, or a projection the Mac would refuse as a whole).
 */
export const buildBlockTree = (row: Input, options: BlockTreeOptions = {}): BlockTree | undefined => {
  const blocks = Array.isArray(row.blocks) ? row.blocks : []
  const text = typeof row.text === "string" ? row.text : ""
  if (blocks.length === 0 || !structureFits(blocks)) return undefined
  const ctx: Context = {
    text,
    entities: row.entities,
    row,
    options,
    claimed: [],
    find: normalizeHighlightRanges(text, options.highlightRanges),
    widgetSeen: false,
  }
  let nodes: RichBlock[]
  try {
    nodes = buildList(ctx, blocks, "", { start: 0, end: text.length }, 0)
  } catch {
    return undefined
  }
  return { kind: "blockTree", text, blocks: nodes, claimedActionIds: ctx.claimed }
}

/** "8s", "1m 4s", "1h 2m"; undefined past 12 hours or for a negative span (Mac `ProgressElapsed`). */
export const formatElapsed = (startedAt: number, now: number): string | undefined => {
  const elapsed = Math.floor(now - startedAt)
  if (!Number.isFinite(elapsed) || elapsed < 0 || elapsed > 12 * 3600) return undefined
  if (elapsed < 60) return `${elapsed}s`
  if (elapsed < 3600) return `${Math.floor(elapsed / 60)}m ${elapsed % 60}s`
  return `${Math.floor(elapsed / 3600)}h ${Math.floor((elapsed % 3600) / 60)}m`
}
