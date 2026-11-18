/**
 * Agent cards (Mac `RichBlockAgentCardNodeViews`, `RichBlockAgentPlan`): plan
 * proposal, approval, review, task suggestion, next step and prompt
 * suggestions. Wording, chips, notes and which buttons show come from the
 * model; buttons call `onAction`, prompts `onCompose`, an opened thread
 * `onOpenPeer`.
 */

import * as stylex from "@stylexjs/stylex"
import {
  type ApprovalBlock,
  documentText,
  type NextStepBlock,
  type PlanProposalBlock,
  type PromptSuggestionsBlock,
  type ReviewBlock,
  type RichBlock,
  type TaskSuggestionBlock,
} from "@inline/chat-ui"
import type { DecisionState } from "@inline/core-protocol"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { type ReactNode, useState } from "react"
import { RichBlocks } from "./BlockViews"
import { ActionButton, CardButtons } from "./ButtonViews"
import { contentText, RichTextView } from "./RichText"
import type { RowContent } from "./row-content"

type CardBlock = PlanProposalBlock | ApprovalBlock | ReviewBlock | TaskSuggestionBlock | NextStepBlock | PromptSuggestionsBlock

export function AgentCard(props: { block: CardBlock; ctx: RowContent }) {
  const { block, ctx } = props
  switch (block.kind) {
    case "planProposal":
      return <PlanCard block={block} ctx={ctx} />
    case "approval":
      return <ApprovalCard block={block} ctx={ctx} />
    case "review":
      return <ReviewCard block={block} ctx={ctx} />
    case "taskSuggestion":
      return <TaskSuggestionCard block={block} ctx={ctx} />
    case "nextStep":
      return <NextStepCard block={block} ctx={ctx} />
    case "promptSuggestions":
      return <PromptChips block={block} ctx={ctx} />
  }
}

function Card(props: {
  kind: string
  dir: string | undefined
  title: ReactNode
  chip?: { text: string; tone: ChipTone } | undefined
  children?: ReactNode
  footer?: ReactNode
}) {
  return (
    <section data-card={props.kind} dir={props.dir ?? "auto"} {...stylex.props(styles.card)}>
      <header {...stylex.props(styles.header)}>
        <div {...stylex.props(styles.title)}>{props.title}</div>
        {props.chip && <span {...stylex.props(styles.chip, chipTones[props.chip.tone])}>{props.chip.text}</span>}
      </header>
      {props.children}
      {props.footer}
    </section>
  )
}

type ChipTone = "accent" | "positive" | "negative" | "neutral" | "warning"

const decisionTone = (state: DecisionState | undefined): ChipTone => {
  switch (state) {
    case "accepted":
      return "positive"
    case "declined":
      return "negative"
    case "expired":
    case "superseded":
      return "neutral"
    default:
      return "accent"
  }
}

/** Buttons while pending, else the decision note. */
function Decision(props: { block: PlanProposalBlock | ApprovalBlock | TaskSuggestionBlock; ctx: RowContent; extra?: ReactNode }) {
  const { block, ctx } = props
  if (block.showButtons && (block.buttons.length > 0 || props.extra)) {
    return (
      <div {...stylex.props(styles.footer)}>
        <CardButtons buttons={block.buttons} ctx={ctx} />
        {props.extra}
      </div>
    )
  }
  if (block.note || props.extra) {
    return (
      <div {...stylex.props(styles.footer)}>
        {block.note && <p {...stylex.props(styles.note)}>{block.note}</p>}
        {props.extra}
      </div>
    )
  }
  return null
}

const titleOf = (block: { title: PlanProposalBlock["title"]; defaultTitle: string }, ctx: RowContent): ReactNode =>
  block.title ? <RichTextView text={block.title} ctx={ctx} /> : block.defaultTitle

/** Rough line count of a plan, for "Show full plan": list items count one each. */
const planLines = (blocks: readonly RichBlock[]): number =>
  blocks.reduce((sum, block) => sum + (block.kind === "list" ? block.items.length : block.kind === "separator" ? 0 : 1), 0)

function PlanCard(props: { block: PlanProposalBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const [expanded, setExpanded] = useState(false)
  const long = planLines(block.children) > block.collapseAfterLines
  const collapsed = long && !expanded
  return (
    <Card
      kind="planProposal"
      dir={block.dir}
      title={titleOf(block, ctx)}
      chip={block.chip ? { text: block.chip, tone: decisionTone(block.state) } : undefined}
      footer={<Decision block={block} ctx={ctx} />}
    >
      <div {...stylex.props(styles.body, collapsed && styles.collapsed, collapsed && dynamic.lines(block.collapseAfterLines))}>
        <RichBlocks blocks={block.children} ctx={ctx} />
      </div>
      {long && (
        <button type="button" aria-expanded={expanded} onClick={() => setExpanded(!expanded)} {...stylex.props(styles.more)}>
          {expanded ? "Show less" : "Show full plan"}
        </button>
      )}
    </Card>
  )
}

function ApprovalCard(props: { block: ApprovalBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <Card
      kind="approval"
      dir={block.dir}
      title={titleOf(block, ctx)}
      chip={block.chip ? { text: block.chip, tone: decisionTone(block.state) } : undefined}
      footer={<Decision block={block} ctx={ctx} />}
    >
      {block.command !== undefined && (
        <pre dir="ltr" tabIndex={0} {...stylex.props(styles.command)}>
          <code>{block.command}</code>
        </pre>
      )}
      {block.cwd !== undefined && (
        <div dir="ltr" {...stylex.props(contentText.mono, contentText.secondary, styles.cwd)}>
          {block.cwd}
        </div>
      )}
      {block.reason && (
        <div {...stylex.props(contentText.secondary)}>
          <RichTextView text={block.reason} ctx={ctx} />
        </div>
      )}
      {block.children.length > 0 && (
        <div {...stylex.props(styles.body)}>
          <RichBlocks blocks={block.children} ctx={ctx} />
        </div>
      )}
    </Card>
  )
}

const verdictTone = (verdict: ReviewBlock["verdict"]): ChipTone =>
  verdict === "correct" ? "positive" : verdict === "incorrect" ? "negative" : verdict === "needsAttention" ? "warning" : "neutral"

const outcomeLabels = { fixed: "Fixed", skipped: "Skipped", noChangeNeeded: "No change needed" } as const

function ReviewCard(props: { block: ReviewBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <Card kind="review" dir={block.dir} title={titleOf(block, ctx)} chip={{ text: block.chip, tone: verdictTone(block.verdict) }}>
      {block.summary && (
        <div {...stylex.props(styles.body)}>
          <RichTextView text={block.summary} ctx={ctx} />
        </div>
      )}
      {block.findings.length > 0 && (
        <ol {...stylex.props(styles.findings)}>
          {block.findings.map((finding) => (
            <li key={finding.key} {...stylex.props(styles.finding)}>
              <div {...stylex.props(styles.findingHead)}>
                {finding.priorityLabel && (
                  <span {...stylex.props(styles.priority, priorityTones[finding.priority ?? "p3"])}>{finding.priorityLabel}</span>
                )}
                <span {...stylex.props(styles.findingTitle)}>
                  <RichTextView text={finding.title} ctx={ctx} />
                </span>
                {finding.outcome && <span {...stylex.props(styles.chip, chipTones.neutral)}>{outcomeLabels[finding.outcome]}</span>}
              </div>
              {(finding.path || finding.category || finding.confidence) && (
                <div {...stylex.props(styles.findingMeta, contentText.caption, contentText.secondary)}>
                  {finding.path && (
                    <span dir="ltr" {...stylex.props(contentText.mono, contentText.ellipsis)}>
                      {finding.lines ? `${finding.path}:${finding.lines}` : finding.path}
                    </span>
                  )}
                  {finding.category && <span>{finding.category}</span>}
                  {finding.confidence && <span>{finding.confidence === "confirmed" ? "Confirmed" : "Plausible"}</span>}
                </div>
              )}
              {finding.body && (
                <div {...stylex.props(contentText.caption)}>
                  <RichTextView text={finding.body} ctx={ctx} />
                </div>
              )}
              {finding.button && (
                <div>
                  <ActionButton button={finding.button} ctx={ctx} />
                </div>
              )}
            </li>
          ))}
        </ol>
      )}
    </Card>
  )
}

function TaskSuggestionCard(props: { block: TaskSuggestionBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const open = ctx.env.handlers.onOpenPeer
  const thread = block.openThread
  return (
    <Card
      kind="taskSuggestion"
      dir={block.dir}
      title={<RichTextView text={block.title} ctx={ctx} />}
      chip={block.chip ? { text: block.chip, tone: decisionTone(block.state) } : undefined}
      footer={
        <Decision
          block={block}
          ctx={ctx}
          extra={
            thread && open ? (
              <button type="button" onClick={() => open(thread)} {...stylex.props(styles.more)}>
                Open thread
              </button>
            ) : undefined
          }
        />
      }
    >
      {block.brief && (
        <div {...stylex.props(contentText.secondary)}>
          <RichTextView text={block.brief} ctx={ctx} />
        </div>
      )}
    </Card>
  )
}

function NextStepCard(props: { block: NextStepBlock; ctx: RowContent }) {
  const { block, ctx } = props
  return (
    <Card
      kind="nextStep"
      dir={block.dir}
      title={<RichTextView text={block.recap} ctx={ctx} />}
      chip={block.chip ? { text: block.chip, tone: "warning" } : undefined}
      footer={
        block.buttons.length > 0 ? (
          <div {...stylex.props(styles.footer)}>
            <CardButtons buttons={block.buttons} ctx={ctx} />
          </div>
        ) : undefined
      }
    >
      {block.question && (
        <div {...stylex.props(styles.question)}>
          <RichTextView text={block.question} ctx={ctx} />
        </div>
      )}
    </Card>
  )
}

function PromptChips(props: { block: PromptSuggestionsBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const compose = ctx.env.handlers.onCompose
  return (
    <div role="group" aria-label="Suggested prompts" dir={block.dir ?? "auto"} {...stylex.props(styles.prompts)}>
      {block.prompts.map((prompt) => (
        <button
          key={prompt.key}
          type="button"
          title={prompt.composeText}
          disabled={!compose}
          onClick={compose ? () => compose(prompt.composeText) : undefined}
          {...stylex.props(styles.prompt)}
        >
          {documentText(prompt.label.document)}
        </button>
      ))}
    </div>
  )
}

const styles = stylex.create({
  card: {
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    minInlineSize: "220px",
    paddingBlock: space.md,
    paddingInline: space.md,
    boxSizing: "border-box",
    borderRadius: radius.content,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    backgroundColor: color.textBackground,
    color: color.label,
  },
  header: { display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: space.md, minInlineSize: 0 },
  title: { fontWeight: font.weightSemibold, minInlineSize: 0, flexGrow: 1 },
  chip: {
    flexShrink: 0,
    paddingInline: space.sm,
    paddingBlock: "1px",
    borderRadius: radius.pill,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightMedium,
    lineHeight: "15px",
    whiteSpace: "nowrap",
  },
  body: { minInlineSize: 0 },
  collapsed: { overflow: "hidden", maskImage: "linear-gradient(to bottom, black 70%, transparent)" },
  more: {
    alignSelf: "flex-start",
    padding: 0,
    borderStyle: "none",
    backgroundColor: "transparent",
    color: color.link,
    fontFamily: "inherit",
    fontSize: font.sizeCallout,
    cursor: "pointer",
    borderRadius: radius.small,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  footer: { display: "flex", alignItems: "center", flexWrap: "wrap", gap: space.md },
  note: { margin: 0, fontSize: font.sizeCallout, color: color.secondaryLabel },
  command: {
    margin: 0,
    paddingBlock: space.sm,
    paddingInline: space.md,
    overflowX: "auto",
    borderRadius: radius.control,
    backgroundColor: `color-mix(in srgb, ${color.label} 6%, transparent)`,
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    whiteSpace: "pre",
    textAlign: "left",
    scrollbarWidth: "thin",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  cwd: { overflowWrap: "anywhere" },
  findings: { margin: 0, padding: 0, listStyleType: "none", display: "flex", flexDirection: "column", gap: space.md },
  finding: {
    display: "flex",
    flexDirection: "column",
    gap: space.xxs,
    paddingBlockStart: space.sm,
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  findingHead: { display: "flex", alignItems: "baseline", gap: space.sm, minInlineSize: 0 },
  findingTitle: { fontWeight: font.weightMedium, flexGrow: 1, minInlineSize: 0 },
  findingMeta: { display: "flex", flexWrap: "wrap", gap: space.md, minInlineSize: 0 },
  priority: {
    flexShrink: 0,
    paddingInline: space.xs,
    borderRadius: radius.small,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightBold,
    color: color.onAccent,
  },
  question: { fontWeight: font.weightMedium },
  prompts: { display: "flex", flexWrap: "wrap", gap: space.sm },
  prompt: {
    maxInlineSize: "100%",
    paddingBlock: space.xs,
    paddingInline: space.lg,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.pill,
    backgroundColor: { default: color.control, ":hover": color.controlHover },
    color: color.controlText,
    fontFamily: "inherit",
    fontSize: font.sizeCallout,
    textAlign: "start",
    cursor: { default: "pointer", ":disabled": "default" },
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
})

const chipTones = stylex.create({
  accent: { color: color.accent, backgroundColor: `color-mix(in srgb, ${color.accent} 14%, transparent)` },
  positive: { color: color.green, backgroundColor: `color-mix(in srgb, ${color.green} 14%, transparent)` },
  negative: { color: color.red, backgroundColor: `color-mix(in srgb, ${color.red} 12%, transparent)` },
  warning: { color: color.orange, backgroundColor: `color-mix(in srgb, ${color.orange} 14%, transparent)` },
  neutral: { color: color.secondaryLabel, backgroundColor: `color-mix(in srgb, ${color.label} 8%, transparent)` },
})

const priorityTones = stylex.create({
  p0: { backgroundColor: color.red },
  p1: { backgroundColor: color.orange },
  p2: { backgroundColor: color.yellow, color: color.label },
  p3: { backgroundColor: color.gray },
})

const dynamic = stylex.create({
  lines: (lines: number) => ({ maxBlockSize: `calc(${lines} * 1.45em)` }),
})
