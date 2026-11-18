/**
 * Rich blocks: one small component per kind in the block tree
 * (`@inline/chat-ui` `buildBlockTree`), after the Mac's `RichContent/` views.
 * Every block is memoized by identity with keys from the model, so a
 * streaming update (`updateBlockTree`) re-renders the one block that changed.
 * Text ranges render through `MessageText`; code, math and diffs are literal.
 */

import * as stylex from "@stylexjs/stylex"
import type {
  CalloutBlock,
  CodeBlock,
  DiffBlock,
  DisclosureBlock,
  FieldsBlock,
  ListBlock,
  MeterBlock,
  RichBlock,
  StepsBlock,
  TableBlock,
  WidgetBlock,
} from "@inline/chat-ui"
import type { BlockStatus } from "@inline/core-protocol"
import { useModel, useSignal } from "@inline/reactive/react"
import { IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, type ReactNode } from "react"
import { AgentCard } from "./AgentCards"
import { FormView } from "./FormView"
import { CheckIcon, ChevronIcon, CircleIcon, ClockIcon, CopyIcon, StopIcon, WarningIcon } from "./icons"
import { Album, BlockImage } from "./MediaViews"
import { contentText, RichTextView } from "./RichText"
import type { RowContent } from "./row-content"
import { ElapsedTimer, TransientFlag } from "./timers"

/** A list of blocks, each memoized. */
export function RichBlocks(props: { blocks: readonly RichBlock[]; ctx: RowContent }) {
  return (
    <>
      {props.blocks.map((block) => (
        <BlockView key={block.key} block={block} ctx={props.ctx} />
      ))}
    </>
  )
}

/** One block. Renders again only when its node or the row context changes identity. */
export const BlockView = memo(function BlockView(props: { block: RichBlock; ctx: RowContent }): ReactNode {
  const { block, ctx } = props
  ctx.env.debug?.onBlockRender?.(ctx.rowId, block.key)
  return (
    <div data-block={block.kind} data-block-key={block.key} {...stylex.props(styles.block)}>
      <BlockBody block={block} ctx={ctx} />
    </div>
  )
})

function BlockBody(props: { block: RichBlock; ctx: RowContent }): ReactNode {
  const { block, ctx } = props
  switch (block.kind) {
    case "paragraph":
    case "fallback":
      return <RichTextView text={block.text} ctx={ctx} />
    case "heading":
      return (
        <div role="heading" aria-level={block.level} {...stylex.props(styles.heading, headingSizes[`h${block.level}`])}>
          <RichTextView text={block.text} ctx={ctx} />
        </div>
      )
    case "footer":
      return (
        <div {...stylex.props(contentText.caption, secondaryTone(ctx))}>
          <RichTextView text={block.text} ctx={ctx} />
        </div>
      )
    case "math":
      return (
        <code dir="ltr" {...stylex.props(styles.math)}>
          {block.source}
        </code>
      )
    case "code":
      return <CodeView block={block} ctx={ctx} />
    case "separator":
      return <hr {...stylex.props(styles.separator)} />
    case "list":
      return <ListView block={block} ctx={ctx} />
    case "image":
      return <BlockImage image={block.image} ctx={ctx} />
    case "album":
      return <Album images={block.images} layout={block.layout} ctx={ctx} />
    case "disclosure":
      return <DisclosureView block={block} ctx={ctx} />
    case "quote":
      return (
        <blockquote dir={block.dir ?? "auto"} {...stylex.props(styles.quote, ctx.tone === "outgoing" && styles.quoteOutgoing)}>
          <RichBlocks blocks={block.children} ctx={ctx} />
        </blockquote>
      )
    case "table":
      return <TableView block={block} ctx={ctx} />
    case "diff":
      return <DiffView block={block} ctx={ctx} />
    case "fields":
      return <FieldsView block={block} ctx={ctx} />
    case "steps":
      return <StepsView block={block} ctx={ctx} />
    case "callout":
      return <CalloutView block={block} ctx={ctx} />
    case "meter":
      return <MeterView block={block} ctx={ctx} />
    case "form":
      return <FormView block={block} ctx={ctx} />
    case "widget":
      return <WidgetPlaceholder block={block} ctx={ctx} />
    case "planProposal":
    case "approval":
    case "review":
    case "taskSuggestion":
    case "nextStep":
    case "promptSuggestions":
      return <AgentCard block={block} ctx={ctx} />
    default:
      return null
  }
}

const secondaryTone = (ctx: RowContent) => (ctx.tone === "outgoing" ? contentText.secondaryOutgoing : contentText.secondary)

// ---------------------------------------------------------------------------
// Code

function CodeView(props: { block: CodeBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const copied = useModel(() => new TransientFlag())
  const isCopied = useSignal(copied.on)
  const copy = ctx.env.handlers.onCopyText
  return (
    <figure {...stylex.props(styles.code, ctx.tone === "outgoing" && styles.codeOutgoing)}>
      <figcaption {...stylex.props(styles.codeHeader)}>
        <span {...stylex.props(styles.codeLanguage)}>{block.language ?? "Code"}</span>
        {copy && (
          <IconButton
            label={isCopied ? "Copied" : "Copy code"}
            icon={isCopied ? <CheckIcon /> : <CopyIcon />}
            size="small"
            onClick={() => {
              copy(block.code)
              copied.trigger()
            }}
          />
        )}
      </figcaption>
      <pre dir="ltr" tabIndex={0} {...stylex.props(styles.codeBody)}>
        <code>{block.code}</code>
      </pre>
    </figure>
  )
}

// ---------------------------------------------------------------------------
// Lists

function ListView(props: { block: ListBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const Tag = block.ordered ? "ol" : "ul"
  return (
    <Tag dir={block.dir ?? "auto"} {...stylex.props(styles.list)}>
      {block.items.map((item) => (
        <li key={item.key} {...stylex.props(styles.listItem)}>
          <span
            aria-hidden={item.marker.kind !== "task" || undefined}
            role={item.marker.kind === "task" ? "img" : undefined}
            aria-label={item.marker.kind === "task" ? (item.marker.checked ? "Done" : "Not done") : undefined}
            {...stylex.props(styles.marker, item.marker.kind === "number" && styles.markerNumber)}
          >
            {item.markerText}
          </span>
          <div {...stylex.props(styles.listBody)}>
            <RichBlocks blocks={item.children} ctx={ctx} />
          </div>
        </li>
      ))}
    </Tag>
  )
}

// ---------------------------------------------------------------------------
// Disclosure

function DisclosureView(props: { block: DisclosureBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const openMap = useSignal(ctx.disclosures.open)
  const open = openMap.get(block.key) ?? block.initiallyOpen
  return (
    <details
      open={open}
      dir={block.dir ?? "auto"}
      onToggle={(event) => {
        // The browser also fires toggle for the initial `open`; only a change is the user's.
        if (event.currentTarget.open !== open) ctx.disclosures.set(block.key, event.currentTarget.open)
      }}
      {...stylex.props(styles.details, block.style === "progress" && styles.detailsProgress)}
    >
      <summary data-activity={block.activity} {...stylex.props(styles.summary, secondaryTone(ctx))}>
        <span aria-hidden="true" {...stylex.props(styles.chevron, open && styles.chevronOpen)}>
          <ChevronIcon />
        </span>
        <span {...stylex.props(styles.summaryText, block.shimmer && styles.shimmer)}>
          <RichTextView text={block.summary} ctx={ctx} />
        </span>
        {block.statusBadge && <StatusBadge status={block.statusBadge} />}
        {block.timer ? (
          <Elapsed startedAt={block.timer.startedAt} />
        ) : (
          block.meta && (
            <span {...stylex.props(styles.summaryMeta)}>
              <RichTextView text={block.meta} ctx={ctx} />
            </span>
          )
        )}
      </summary>
      {open && (
        <div {...stylex.props(styles.detailsBody)}>
          <RichBlocks blocks={block.children} ctx={ctx} />
        </div>
      )}
    </details>
  )
}

function Elapsed(props: { startedAt: number }) {
  const timer = useModel(() => new ElapsedTimer(props.startedAt), [props.startedAt])
  const text = useSignal(timer.text)
  if (!text) return null
  return <span {...stylex.props(styles.summaryMeta, styles.tabular)}>{text}</span>
}

const statusLabels: Record<BlockStatus, string> = {
  pending: "Pending",
  running: "Running",
  waiting: "Waiting",
  done: "Done",
  failed: "Failed",
  cancelled: "Cancelled",
}

export function StatusBadge(props: { status: BlockStatus }) {
  const { status } = props
  return (
    <span role="img" aria-label={statusLabels[status]} title={statusLabels[status]} {...stylex.props(styles.status, statusTones[status])}>
      {status === "failed" ? (
        <WarningIcon />
      ) : status === "cancelled" ? (
        <StopIcon />
      ) : status === "waiting" ? (
        <ClockIcon />
      ) : status === "done" ? (
        <CheckIcon size={12} />
      ) : (
        <CircleIcon filled={status === "running"} />
      )}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Table

function TableView(props: { block: TableBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <div role="region" aria-label="Table" tabIndex={0} {...stylex.props(styles.tableScroller)}>
      <table dir={block.dir ?? "auto"} {...stylex.props(styles.table)}>
        {block.header.length > 0 && (
          <thead>
            <tr>
              {block.header.map((cell, index) => (
                <th key={cell.key} scope="col" {...stylex.props(styles.cell, styles.headerCell, alignStyles[block.alignments[index] ?? "start"])}>
                  <RichTextView text={cell.text} ctx={ctx} />
                </th>
              ))}
            </tr>
          </thead>
        )}
        <tbody>
          {block.rows.map((row) => (
            <tr key={row.map((cell) => cell.key).join("|")}>
              {row.map((cell, index) => (
                <td key={cell.key} {...stylex.props(styles.cell, alignStyles[block.alignments[index] ?? "start"])}>
                  <RichTextView text={cell.text} ctx={ctx} />
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Diff

const changeLabels: Record<DiffBlock["change"], string> = {
  added: "Added",
  modified: "Modified",
  deleted: "Deleted",
  renamed: "Renamed",
}

function DiffView(props: { block: DiffBlock; ctx: RowContent }) {
  const { block } = props
  return (
    <figure {...stylex.props(styles.code)}>
      <figcaption {...stylex.props(styles.codeHeader)}>
        <span dir="ltr" title={block.previousPath ? `${block.previousPath} → ${block.path}` : block.path} {...stylex.props(styles.diffPath)}>
          {block.previousPath ? `${block.previousPath} → ${block.path}` : block.path}
        </span>
        <span {...stylex.props(styles.diffStats)}>
          <span {...stylex.props(styles.diffChange)}>{changeLabels[block.change]}</span>
          {block.additions !== undefined && <span {...stylex.props(styles.diffAdd)}>+{block.additions}</span>}
          {block.deletions !== undefined && <span {...stylex.props(styles.diffDelete)}>−{block.deletions}</span>}
        </span>
      </figcaption>
      {block.lines.length > 0 && (
        <pre dir="ltr" tabIndex={0} {...stylex.props(styles.codeBody, styles.diffBody)}>
          {block.lines.map((line) => (
            <span key={line.key} {...stylex.props(styles.diffLine, diffLineStyles[line.kind])}>
              {line.text.length > 0 ? line.text : " "}
            </span>
          ))}
        </pre>
      )}
      {block.footer && <div {...stylex.props(styles.diffFooter)}>{block.footer}</div>}
    </figure>
  )
}

// ---------------------------------------------------------------------------
// Fields, steps, callout, meter

function FieldsView(props: { block: FieldsBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <dl dir={block.dir ?? "auto"} {...stylex.props(styles.fields)}>
      {block.fields.map((field) => (
        <div key={field.key} {...stylex.props(styles.field)}>
          <dt {...stylex.props(styles.fieldLabel, secondaryTone(ctx))}>
            <RichTextView text={field.label} ctx={ctx} />
          </dt>
          <dd {...stylex.props(styles.fieldValue)}>
            {field.code !== undefined ? (
              <code dir="ltr" {...stylex.props(contentText.mono, styles.fieldCode)}>
                {field.code}
              </code>
            ) : (
              field.value && <RichTextView text={field.value} ctx={ctx} />
            )}
          </dd>
        </div>
      ))}
    </dl>
  )
}

function StepsView(props: { block: StepsBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <ol dir={block.dir ?? "auto"} {...stylex.props(styles.steps, block.card && styles.card)}>
      {block.steps.map((step) => (
        <li key={step.key} {...stylex.props(styles.step)}>
          <span {...stylex.props(styles.stepIcon)}>
            <StatusBadge status={step.status ?? "pending"} />
          </span>
          <div {...stylex.props(styles.stepText, step.status === "done" && styles.stepDone)}>
            <RichTextView text={step.text} ctx={ctx} />
            {step.detail && (
              <div {...stylex.props(contentText.caption, secondaryTone(ctx))}>
                <RichTextView text={step.detail} ctx={ctx} />
              </div>
            )}
          </div>
        </li>
      ))}
    </ol>
  )
}

function CalloutView(props: { block: CalloutBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <aside role="note" dir={block.dir ?? "auto"} {...stylex.props(styles.callout, calloutTones[block.tone])}>
      {block.title && (
        <div {...stylex.props(styles.calloutTitle)}>
          <RichTextView text={block.title} ctx={ctx} />
        </div>
      )}
      <RichBlocks blocks={block.children} ctx={ctx} />
    </aside>
  )
}

function MeterView(props: { block: MeterBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <div {...stylex.props(styles.meter)}>
      <div {...stylex.props(styles.meterHead)}>
        <RichTextView text={block.label} ctx={ctx} />
        {block.meta && (
          <span {...stylex.props(contentText.caption, secondaryTone(ctx))}>
            <RichTextView text={block.meta} ctx={ctx} />
          </span>
        )}
      </div>
      <div
        role="meter"
        aria-valuemin={0}
        aria-valuemax={block.max}
        aria-valuenow={block.value}
        aria-label={block.label.document.text}
        {...stylex.props(styles.meterTrack)}
      >
        <span {...stylex.props(styles.meterFill, meterTones[block.tone], dynamic.fraction(block.fraction))} />
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Widget: a placeholder of the reserved size. Never an iframe here.

function WidgetPlaceholder(props: { block: WidgetBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const height = Math.min(block.height, block.maxInlineHeight)
  return (
    <div
      role="img"
      aria-label={`${block.title.document.text || "Widget"}: not shown here yet`}
      data-widget-id={block.widgetId}
      {...stylex.props(styles.widget, dynamic.height(height))}
    >
      <div {...stylex.props(styles.widgetTitle)}>
        <RichTextView text={block.title} ctx={ctx} />
      </div>
      <p {...stylex.props(styles.widgetNote)}>This widget’s content isn’t shown here yet.</p>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Styles

const shimmer = stylex.keyframes({
  "0%": { opacity: 1 },
  "50%": { opacity: 0.45 },
  "100%": { opacity: 1 },
})

const styles = stylex.create({
  block: {
    minInlineSize: 0,
    marginBlockStart: { default: space.md, ":first-child": 0 },
  },
  heading: { fontWeight: font.weightSemibold, lineHeight: font.lineHeightTight },
  math: {
    display: "block",
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    whiteSpace: "pre-wrap",
    overflowWrap: "anywhere",
  },
  separator: {
    marginBlock: space.xs,
    marginInline: 0,
    borderStyle: "none",
    blockSize: "1px",
    backgroundColor: color.separator,
  },
  quote: {
    margin: 0,
    paddingInlineStart: space.md,
    borderInlineStartWidth: "3px",
    borderInlineStartStyle: "solid",
    borderInlineStartColor: color.accent,
  },
  quoteOutgoing: { borderInlineStartColor: `color-mix(in srgb, ${color.onAccent} 70%, transparent)` },
  code: {
    margin: 0,
    minInlineSize: 0,
    maxInlineSize: "100%",
    overflow: "hidden",
    borderRadius: radius.control,
    backgroundColor: `color-mix(in srgb, ${color.label} 6%, transparent)`,
  },
  codeOutgoing: { backgroundColor: `color-mix(in srgb, ${color.onAccent} 15%, transparent)` },
  codeHeader: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: space.md,
    minBlockSize: "24px",
    paddingInlineStart: space.md,
    paddingInlineEnd: space.xxs,
    paddingBlock: space.xxs,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
  },
  codeLanguage: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  codeBody: {
    margin: 0,
    paddingBlock: space.sm,
    paddingInline: space.md,
    overflowX: "auto",
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    lineHeight: 1.45,
    whiteSpace: "pre",
    textAlign: "left",
    scrollbarWidth: "thin",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "-2px",
  },
  list: { margin: 0, padding: 0, listStyleType: "none", display: "flex", flexDirection: "column", gap: space.xxs },
  listItem: { display: "flex", alignItems: "baseline", gap: space.sm, minInlineSize: 0 },
  marker: { flexShrink: 0, minInlineSize: "1em", textAlign: "end", userSelect: "none" },
  markerNumber: { fontVariantNumeric: "tabular-nums" },
  listBody: { flexGrow: 1, minInlineSize: 0 },
  details: { minInlineSize: 0 },
  detailsProgress: {},
  summary: {
    display: "flex",
    alignItems: "center",
    gap: space.xs,
    minInlineSize: 0,
    cursor: "pointer",
    listStyleType: "none",
    fontSize: font.sizeCallout,
    borderRadius: radius.small,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    "::-webkit-details-marker": { display: "none" },
  },
  chevron: {
    display: "inline-flex",
    flexShrink: 0,
    transitionProperty: "transform",
    transitionDuration: motion.durationFast,
    transform: { default: null, ":dir(rtl)": "scaleX(-1)" },
  },
  chevronOpen: { transform: { default: "rotate(90deg)", ":dir(rtl)": "scaleX(-1) rotate(90deg)" } },
  summaryText: { flexGrow: 1, minInlineSize: 0, overflow: "hidden" },
  shimmer: {
    animationName: { default: shimmer, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "1.6s",
    animationIterationCount: "infinite",
    animationTimingFunction: "ease-in-out",
  },
  summaryMeta: { flexShrink: 0, color: color.secondaryLabel },
  tabular: { fontVariantNumeric: "tabular-nums" },
  detailsBody: {
    marginBlockStart: space.sm,
    paddingInlineStart: space.lg,
    borderInlineStartWidth: "1px",
    borderInlineStartStyle: "solid",
    borderInlineStartColor: color.separator,
  },
  status: { display: "inline-flex", alignItems: "center", flexShrink: 0 },
  tableScroller: {
    maxInlineSize: "100%",
    overflowX: "auto",
    scrollbarWidth: "thin",
    borderRadius: radius.small,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  table: { borderCollapse: "collapse", fontSize: font.sizeCallout, minInlineSize: "100%" },
  cell: {
    paddingBlock: space.xs,
    paddingInline: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    verticalAlign: "top",
    minInlineSize: "48px",
  },
  headerCell: { fontWeight: font.weightSemibold, backgroundColor: `color-mix(in srgb, ${color.label} 4%, transparent)` },
  diffPath: {
    fontFamily: font.familyMono,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    minInlineSize: 0,
    color: color.label,
  },
  diffStats: { display: "inline-flex", gap: space.sm, flexShrink: 0, paddingInlineEnd: space.sm, fontVariantNumeric: "tabular-nums" },
  diffChange: { color: color.secondaryLabel },
  diffAdd: { color: color.green },
  diffDelete: { color: color.red },
  diffBody: { paddingInline: 0 },
  diffLine: { display: "block", paddingInline: space.md, minInlineSize: "max-content" },
  diffFooter: { paddingBlock: space.xs, paddingInline: space.md, fontSize: font.sizeCallout, color: color.secondaryLabel },
  fields: { display: "grid", gridTemplateColumns: "minmax(min-content, max-content) 1fr", columnGap: space.lg, rowGap: space.xs, margin: 0 },
  field: { display: "contents" },
  fieldLabel: { fontSize: font.sizeCallout, minInlineSize: 0 },
  fieldValue: { margin: 0, minInlineSize: 0, overflowWrap: "anywhere" },
  fieldCode: { overflowWrap: "anywhere" },
  steps: { margin: 0, padding: 0, listStyleType: "none", display: "flex", flexDirection: "column", gap: space.xs },
  card: {
    paddingBlock: space.md,
    paddingInline: space.md,
    borderRadius: radius.content,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
  },
  step: { display: "flex", alignItems: "flex-start", gap: space.sm },
  stepIcon: { display: "inline-flex", paddingBlockStart: "3px" },
  stepText: { minInlineSize: 0, flexGrow: 1 },
  stepDone: { color: color.secondaryLabel },
  callout: {
    display: "flex",
    flexDirection: "column",
    gap: space.xs,
    paddingBlock: space.md,
    paddingInline: space.md,
    borderRadius: radius.control,
    borderInlineStartWidth: "3px",
    borderInlineStartStyle: "solid",
  },
  calloutTitle: { fontWeight: font.weightSemibold },
  meter: { display: "flex", flexDirection: "column", gap: space.xs },
  meterHead: { display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: space.md },
  meterTrack: {
    position: "relative",
    blockSize: "6px",
    borderRadius: radius.pill,
    overflow: "hidden",
    backgroundColor: color.controlTrack,
  },
  meterFill: { position: "absolute", insetBlock: 0, insetInlineStart: 0, borderRadius: radius.pill },
  widget: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    gap: space.xs,
    inlineSize: "100%",
    minInlineSize: "200px",
    paddingInline: space.lg,
    boxSizing: "border-box",
    borderRadius: radius.content,
    borderWidth: "1px",
    borderStyle: "dashed",
    borderColor: color.separator,
    backgroundColor: `color-mix(in srgb, ${color.label} 3%, transparent)`,
    overflow: "hidden",
  },
  widgetTitle: { fontWeight: font.weightSemibold },
  widgetNote: { margin: 0, fontSize: font.sizeCallout, color: color.secondaryLabel },
})

const headingSizes = stylex.create({
  h1: { fontSize: font.sizeTitle2 },
  h2: { fontSize: font.sizeTitle3 },
  h3: { fontSize: font.sizeHeadline },
  h4: { fontSize: font.sizeBody },
  h5: { fontSize: font.sizeCallout },
  h6: { fontSize: font.sizeCallout, color: color.secondaryLabel },
})

const alignStyles = stylex.create({
  start: { textAlign: "start" },
  left: { textAlign: "left" },
  center: { textAlign: "center" },
  right: { textAlign: "right" },
})

const diffLineStyles = stylex.create({
  hunk: { color: color.secondaryLabel, backgroundColor: `color-mix(in srgb, ${color.blue} 10%, transparent)` },
  add: { backgroundColor: `color-mix(in srgb, ${color.green} 16%, transparent)` },
  delete: { backgroundColor: `color-mix(in srgb, ${color.red} 14%, transparent)` },
  context: {},
})

const statusTones = stylex.create({
  pending: { color: color.tertiaryLabel },
  running: { color: color.accent },
  waiting: { color: color.orange },
  done: { color: color.green },
  failed: { color: color.red },
  cancelled: { color: color.secondaryLabel },
})

const calloutTones = stylex.create({
  info: { borderInlineStartColor: color.blue, backgroundColor: `color-mix(in srgb, ${color.blue} 9%, transparent)` },
  success: { borderInlineStartColor: color.green, backgroundColor: `color-mix(in srgb, ${color.green} 10%, transparent)` },
  warning: { borderInlineStartColor: color.orange, backgroundColor: `color-mix(in srgb, ${color.orange} 11%, transparent)` },
  error: { borderInlineStartColor: color.red, backgroundColor: `color-mix(in srgb, ${color.red} 10%, transparent)` },
})

const meterTones = stylex.create({
  normal: { backgroundColor: color.accent },
  warning: { backgroundColor: color.orange },
  critical: { backgroundColor: color.red },
})

const dynamic = stylex.create({
  fraction: (fraction: number) => ({ inlineSize: `${Math.round(fraction * 1000) / 10}%` }),
  height: (height: number) => ({ blockSize: `${height}px` }),
})
