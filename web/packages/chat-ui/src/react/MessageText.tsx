/**
 * Thin React view over the text render model. Renders semantic elements, text
 * as text nodes, and links only from `safeLink` output. No HTML strings, no
 * effects, no StyleX: styling comes in through `classNames` and the
 * `data-kind` attributes, so this file stays portable and testable in a DOM
 * shim.
 *
 * Paragraph text keeps its line breaks and spaces: style paragraphs with
 * `white-space: pre-wrap` (and code blocks with `pre`).
 *
 * `inline` renders phrasing content only, for places where `div` and `p` are
 * invalid (`summary`, `label`, table cells, buttons): `span` wrappers, line
 * breaks as `<br>`, one `<br>` between blocks, a code block as `code`, a
 * quote as a `span` of its paragraphs, display math as `code`. The default
 * output is unchanged.
 *
 * `highlightRanges` marks find-in-chat matches (UTF-16 `[start, end)` into the
 * document's text) as `<mark data-kind="find">`, inside links and mentions,
 * across marks and lines, and inside code blocks. Unchanged ranges keep node
 * identity; changing them re-renders only the paragraphs they touch.
 */

import { memo, useMemo, type KeyboardEvent, type MouseEvent, type ReactNode } from "react"
import type { AppLink, MailLink, PhoneLink, WebLink } from "../links"
import { highlightTextDocument } from "../text/highlight"
import type {
  BlockNode,
  CodeBlockNode,
  HighlightRange,
  BotCommandNode,
  InlineNode,
  LinkNode,
  Mark,
  MentionTarget,
  ParagraphNode,
  TextDocument,
  TextRun,
  ThreadTarget,
} from "../text/types"

export type MessageTextEvent = MouseEvent<HTMLElement> | KeyboardEvent<HTMLElement>

export type MessageTextHandlers = {
  /** A mention was activated. Without it, mentions render as styled text. */
  readonly onMention?: (target: MentionTarget, event: MessageTextEvent) => void
  /** A thread reference was activated. */
  readonly onThreadRef?: (target: ThreadTarget, event: MessageTextEvent) => void
  /** A bot command was activated. */
  readonly onBotCommand?: (node: BotCommandNode, event: MessageTextEvent) => void
  /**
   * An in-app link was clicked. The default navigation is prevented when this
   * is set; map `link.href` to a destination with the view package's `parseLink`.
   */
  readonly onAppLink?: (link: AppLink, event: MouseEvent<HTMLAnchorElement>) => void
  /**
   * An external link was clicked. Called before the browser follows it; call
   * `event.preventDefault()` to handle it yourself (Electron opens the system browser).
   */
  readonly onExternalLink?: (link: WebLink | MailLink | PhoneLink, event: MouseEvent<HTMLAnchorElement>) => void
}

export type MessageTextClassKey =
  | "root"
  | "paragraph"
  | "codeBlock"
  | "quote"
  | "mathBlock"
  | "link"
  | "mention"
  | "threadRef"
  | "botCommand"
  | "math"
  | Mark

export type MessageTextClassNames = Partial<Record<MessageTextClassKey, string>>

export type MessageTextProps = MessageTextHandlers & {
  readonly document: TextDocument
  readonly classNames?: MessageTextClassNames
  /** Phrasing content only (`span`, `br`, `code`), for `summary`, `label`, table cells. Default false. */
  readonly inline?: boolean
  /** Find-in-chat matches: UTF-16 `[start, end)` ranges into `document.text`. Malformed ranges are ignored. */
  readonly highlightRanges?: readonly HighlightRange[]
}

type Context = MessageTextHandlers & { readonly classNames: MessageTextClassNames; readonly inline?: boolean }

/** Text with each line break as `<br>`, for the inline variant. */
const withBreaks = (text: string): ReactNode => {
  if (!text.includes("\n")) return text
  const parts = text.split(/\r\n|\n/)
  return parts.map((part, index) => (index === 0 ? part : [<br key={`b${index}`} />, part]))
}

const markElements: Record<Mark, "strong" | "em" | "u" | "s" | "mark" | "code"> = {
  find: "mark",
  bold: "strong",
  italic: "em",
  underline: "u",
  strikethrough: "s",
  highlight: "mark",
  code: "code",
}

const Run = ({ run, ctx }: { run: TextRun; ctx: Context }): ReactNode => {
  let content: ReactNode = ctx.inline ? withBreaks(run.text) : run.text
  // Marks are in canonical order; wrap from the innermost (code) out.
  for (let i = run.marks.length - 1; i >= 0; i -= 1) {
    const mark = run.marks[i]
    if (!mark) continue
    if (mark === "find") {
      content = (
        <mark className={ctx.classNames.find} data-kind="find">
          {content}
        </mark>
      )
      continue
    }
    const Tag = markElements[mark]
    content = (
      <Tag className={ctx.classNames[mark]} data-mark={mark}>
        {content}
      </Tag>
    )
  }
  return content
}

/** Code text with its find matches as `<mark data-kind="find">`; plain text without any. */
const codeText = (node: CodeBlockNode, ctx: Context, render: (text: string) => ReactNode): ReactNode => {
  const find = node.find
  if (!find || find.length === 0) return render(node.text)
  const parts: ReactNode[] = []
  let cursor = 0
  for (const span of find) {
    if (span.start > cursor) parts.push(render(node.text.slice(cursor, span.start)))
    parts.push(
      <mark key={`f${span.start}`} className={ctx.classNames.find} data-kind="find">
        {render(node.text.slice(span.start, span.end))}
      </mark>,
    )
    cursor = span.end
  }
  if (cursor < node.text.length) parts.push(render(node.text.slice(cursor)))
  return parts
}

const runs = (children: readonly TextRun[], ctx: Context): ReactNode =>
  children.map((run) => <Run key={run.key} run={run} ctx={ctx} />)

const activateOnEnter =
  (activate: (event: MessageTextEvent) => void) =>
  (event: KeyboardEvent<HTMLElement>): void => {
    if (event.key !== "Enter") return
    event.preventDefault()
    activate(event)
  }

/** Mentions, thread references and bot commands: a span, made a keyboard-reachable link when it has a handler. */
const Interactive = ({
  kind,
  className,
  data,
  onActivate,
  children,
}: {
  kind: "mention" | "threadRef" | "botCommand"
  className: string | undefined
  data: Record<`data-${string}`, string | undefined>
  onActivate: ((event: MessageTextEvent) => void) | undefined
  children: ReactNode
}): ReactNode =>
  onActivate ? (
    <span
      className={className}
      data-kind={kind}
      {...data}
      role="link"
      tabIndex={0}
      onClick={onActivate}
      onKeyDown={activateOnEnter(onActivate)}
    >
      {children}
    </span>
  ) : (
    <span className={className} data-kind={kind} {...data}>
      {children}
    </span>
  )

const LinkView = ({ node, ctx }: { node: LinkNode; ctx: Context }): ReactNode => {
  const link = node.link
  if (link.kind === "app") {
    const onAppLink = ctx.onAppLink
    return (
      <a
        className={ctx.classNames.link}
        data-kind="link"
        data-link-kind="app"
        href={link.href}
        rel="noopener noreferrer"
        onClick={
          onAppLink
            ? (event) => {
                event.preventDefault()
                onAppLink(link, event)
              }
            : undefined
        }
      >
        {runs(node.children, ctx)}
      </a>
    )
  }
  const onExternalLink = ctx.onExternalLink
  return (
    <a
      className={ctx.classNames.link}
      data-kind="link"
      data-link-kind={link.kind}
      href={link.href}
      rel="noopener noreferrer"
      target={link.kind === "web" ? "_blank" : undefined}
      onClick={onExternalLink ? (event) => onExternalLink(link, event) : undefined}
    >
      {runs(node.children, ctx)}
    </a>
  )
}

const mentionData = (target: MentionTarget): Record<`data-${string}`, string | undefined> => {
  switch (target.kind) {
    case "user":
      return { "data-mention": "user", "data-user-id": target.userId }
    case "username":
      return { "data-mention": "username", "data-username": target.username }
    case "group":
      return { "data-mention": "group", "data-group-id": target.groupId }
  }
}

const threadData = (target: ThreadTarget): Record<`data-${string}`, string | undefined> =>
  target.kind === "chat" ? { "data-chat-id": target.chatId } : { "data-space-id": target.spaceId, "data-title": target.title }

const Inline = memo(function Inline({ node, ctx }: { node: InlineNode; ctx: Context }): ReactNode {
  switch (node.kind) {
    case "text":
      return <Run run={node} ctx={ctx} />
    case "link":
      return <LinkView node={node} ctx={ctx} />
    case "mention": {
      const { onMention } = ctx
      return (
        <Interactive
          kind="mention"
          className={ctx.classNames.mention}
          data={mentionData(node.target)}
          onActivate={onMention ? (event) => onMention(node.target, event) : undefined}
        >
          {runs(node.children, ctx)}
        </Interactive>
      )
    }
    case "threadRef": {
      const { onThreadRef } = ctx
      return (
        <Interactive
          kind="threadRef"
          className={ctx.classNames.threadRef}
          data={threadData(node.target)}
          onActivate={onThreadRef ? (event) => onThreadRef(node.target, event) : undefined}
        >
          {runs(node.children, ctx)}
        </Interactive>
      )
    }
    case "botCommand": {
      const { onBotCommand } = ctx
      return (
        <Interactive
          kind="botCommand"
          className={ctx.classNames.botCommand}
          data={{ "data-command": node.command }}
          onActivate={onBotCommand ? (event) => onBotCommand(node, event) : undefined}
        >
          {runs(node.children, ctx)}
        </Interactive>
      )
    }
    case "math":
      return (
        <code className={ctx.classNames.math} data-kind="math">
          {node.source}
        </code>
      )
    default:
      return null
  }
})

const Paragraph = ({ node, ctx }: { node: ParagraphNode; ctx: Context }): ReactNode => (
  <p className={ctx.classNames.paragraph} data-kind="paragraph" dir={node.dir ?? "auto"}>
    {node.children.map((child) => (
      <Inline key={child.key} node={child} ctx={ctx} />
    ))}
  </p>
)

const InlineParagraph = ({ node, ctx }: { node: ParagraphNode; ctx: Context }): ReactNode => (
  <span className={ctx.classNames.paragraph} data-kind="paragraph" dir={node.dir ?? "auto"}>
    {node.children.map((child) => (
      <Inline key={child.key} node={child} ctx={ctx} />
    ))}
  </span>
)

/** The inline variant's blocks: phrasing content only. */
const InlineBlock = memo(function InlineBlock({ node, ctx }: { node: BlockNode; ctx: Context }): ReactNode {
  switch (node.kind) {
    case "paragraph":
      return <InlineParagraph node={node} ctx={ctx} />
    case "codeBlock":
      return (
        <code className={ctx.classNames.codeBlock} data-kind="codeBlock" data-language={node.language} dir="ltr">
          {codeText(node, ctx, withBreaks)}
        </code>
      )
    case "quote":
      return (
        <span className={ctx.classNames.quote} data-kind="quote" dir={node.dir ?? "auto"}>
          {node.children.map((child, index) => [
            index > 0 ? <br key={`b${child.key}`} /> : null,
            <InlineParagraph key={child.key} node={child} ctx={ctx} />,
          ])}
        </span>
      )
    case "mathBlock":
      return (
        <code className={ctx.classNames.mathBlock} data-kind="mathBlock" dir="ltr">
          {node.source}
        </code>
      )
    default:
      return null
  }
})

const Block = memo(function Block({ node, ctx }: { node: BlockNode; ctx: Context }): ReactNode {
  switch (node.kind) {
    case "paragraph":
      return <Paragraph node={node} ctx={ctx} />
    case "codeBlock":
      return (
        <pre className={ctx.classNames.codeBlock} data-kind="codeBlock" data-language={node.language} dir="ltr">
          <code>{codeText(node, ctx, (text) => text)}</code>
        </pre>
      )
    case "quote":
      return (
        <blockquote className={ctx.classNames.quote} data-kind="quote" dir={node.dir ?? "auto"}>
          {node.children.map((child) => (
            <Paragraph key={child.key} node={child} ctx={ctx} />
          ))}
        </blockquote>
      )
    case "mathBlock":
      return (
        <code className={ctx.classNames.mathBlock} data-kind="mathBlock" dir="ltr">
          {node.source}
        </code>
      )
    default:
      // A block kind this view does not know yet renders as nothing.
      return null
  }
})

const emptyClassNames: MessageTextClassNames = {}

/** Renders a message's text document. */
export const MessageText = (props: MessageTextProps): ReactNode => {
  const { classNames, onMention, onThreadRef, onBotCommand, onAppLink, onExternalLink } = props
  // Stable while the handlers are, so memoized blocks bail out when their node is unchanged.
  const ctx = useMemo<Context>(
    () => ({ classNames: classNames ?? emptyClassNames, onMention, onThreadRef, onBotCommand, onAppLink, onExternalLink }),
    [classNames, onMention, onThreadRef, onBotCommand, onAppLink, onExternalLink],
  )
  const inlineCtx = useMemo<Context>(() => ({ ...ctx, inline: true }), [ctx])
  const doc = props.highlightRanges && props.highlightRanges.length > 0 ? highlightTextDocument(props.document, props.highlightRanges) : props.document
  if (props.inline) {
    return (
      <span className={ctx.classNames.root} data-kind="messageText" dir={doc.dir ?? "auto"}>
        {doc.blocks.map((block, index) => [
          index > 0 ? <br key={`b${block.key}`} data-kind="blockBreak" /> : null,
          <InlineBlock key={block.key} node={block} ctx={inlineCtx} />,
        ])}
      </span>
    )
  }
  return (
    <div className={ctx.classNames.root} data-kind="messageText" dir={doc.dir ?? "auto"}>
      {doc.blocks.map((block) => (
        <Block key={block.key} node={block} ctx={ctx} />
      ))}
    </div>
  )
}
