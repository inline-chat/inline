// Generated from packages/agent-activity/src by `bun run sync` there. Edit the source, not this copy.
import {
  ActivityKindValue,
  BlockStatusValue,
  DiffChangeValue,
  DisclosureKindValue,
  type ActivityKindName,
  type Block,
  type BlockContent,
  type BlockText,
  type StatusName,
} from "./protocol.js"

/**
 * One message: readable plain text plus blocks that are UTF-16 ranges into
 * it. The text is the complete fallback for apps that predate the blocks.
 */
export type Doc = {
  text: string
  blockContent: BlockContent
}

export type DiffChangeName = keyof typeof DiffChangeValue

const statusValue = (status: StatusName) =>
  status === "none" ? BlockStatusValue.unspecified : BlockStatusValue[status]

/** Appends text and blocks; nested builders share the same text. */
export class DocBuilder {
  private text = ""
  private blocks: Block[] = []

  isEmpty(): boolean {
    return this.text.trim() === ""
  }

  finish(): Doc {
    return { text: this.text.replace(/\n+$/, ""), blockContent: { blocks: this.blocks } }
  }

  /** Appends `text` and a newline; returns the range of `text`. */
  private span(text: string): BlockText {
    const offset = this.text.length
    this.text += `${text}\n`
    return { offset: BigInt(offset), length: BigInt(text.length) }
  }

  private raw(text: string): void {
    this.text += text
  }

  /** Builds children into this builder's text, returning their blocks. */
  private nested(build: (inner: DocBuilder) => void): Block[] {
    const inner = new DocBuilder()
    inner.text = this.text
    build(inner)
    this.text = inner.text
    return inner.blocks
  }

  paragraph(text: string): void {
    if (text.trim() === "") return
    this.blocks.push({ kind: { oneofKind: "paragraph", paragraph: this.span(text.trimEnd()) } })
  }

  footer(text: string): void {
    this.blocks.push({ kind: { oneofKind: "footer", footer: this.span(text) } })
  }

  code(text: string, language?: string): void {
    if (text === "") return
    const range = this.span(text.replace(/\n+$/, ""))
    this.blocks.push({ kind: { oneofKind: "code", code: { text: range, ...(language ? { language } : {}) } } })
  }

  steps(steps: ReadonlyArray<{ text: string; status: StatusName }>): void {
    if (steps.length === 0) return
    const blocks = steps.map(({ text, status }) => {
      this.raw(status === "done" ? "[x] " : status === "running" ? "[>] " : "[ ] ")
      return { text: this.span(text), status: statusValue(status) }
    })
    this.blocks.push({ kind: { oneofKind: "steps", steps: { steps: blocks } } })
  }

  diff(path: string, change: DiffChangeName, diff?: string, counts?: { additions?: number; deletions?: number }): void {
    const added = counts?.additions ?? (diff ? diff.split("\n").filter((line) => line.startsWith("+") && !line.startsWith("+++")).length : undefined)
    const removed = counts?.deletions ?? (diff ? diff.split("\n").filter((line) => line.startsWith("-") && !line.startsWith("---")).length : undefined)
    const pathRange = this.span(path)
    const text = diff ? this.span(diff.trimEnd()) : undefined
    this.blocks.push({
      kind: {
        oneofKind: "diff",
        diff: {
          path: pathRange,
          ...(text ? { text } : {}),
          change: DiffChangeValue[change],
          ...(added !== undefined ? { additions: added } : {}),
          ...(removed !== undefined ? { deletions: removed } : {}),
        },
      },
    })
  }

  /** A collapsible row; `build` writes its children. */
  disclosure(
    summary: string,
    options: { meta?: string; activity?: ActivityKindName; status?: StatusName },
    build: (inner: DocBuilder) => void,
  ): void {
    const summaryRange: BlockText = { offset: BigInt(this.text.length), length: BigInt(summary.length) }
    this.raw(summary)
    const meta = options.meta ? this.metaRange(options.meta) : undefined
    this.raw("\n")
    const children = this.nested(build)
    this.blocks.push({
      kind: {
        oneofKind: "disclosure",
        disclosure: {
          summary: summaryRange,
          kind: DisclosureKindValue.default,
          children,
          activityKind: ActivityKindValue[options.activity ?? "unspecified"],
          status: statusValue(options.status ?? "none"),
          ...(meta ? { meta } : {}),
        },
      },
    })
  }

  /**
   * A progress message's outer row: "Working", open and counting up from
   * `startedAt` while `working`; afterwards its final summary, closed.
   * While working, `elapsed` is the time as of this edit for apps that
   * can't count.
   */
  progress(
    summary: string,
    working: boolean,
    elapsed: { startedAtSeconds: number; text: string } | undefined,
    build: (inner: DocBuilder) => void,
  ): void {
    const summaryRange: BlockText = { offset: BigInt(this.text.length), length: BigInt(summary.length) }
    this.raw(summary)
    const live = working ? elapsed : undefined
    const meta = live ? this.metaRange(live.text) : undefined
    this.raw("\n")
    const children = this.nested(build)
    this.blocks.push({
      kind: {
        oneofKind: "disclosure",
        disclosure: {
          summary: summaryRange,
          kind: working ? DisclosureKindValue.progress : DisclosureKindValue.default,
          initiallyOpen: working,
          children,
          activityKind: ActivityKindValue.unspecified,
          status: BlockStatusValue.unspecified,
          ...(meta ? { meta } : {}),
          ...(live ? { startedAt: BigInt(Math.max(0, Math.floor(live.startedAtSeconds))) } : {}),
        },
      },
    })
  }

  private metaRange(meta: string): BlockText {
    this.raw(" · ")
    const range: BlockText = { offset: BigInt(this.text.length), length: BigInt(meta.length) }
    this.raw(meta)
    return range
  }
}
