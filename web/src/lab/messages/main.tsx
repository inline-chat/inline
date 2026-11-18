/**
 * Message lab: every case the message row views handle, a streaming row, and
 * 500 rows in a plain scrolling container to judge density. Switch light,
 * dark, direction and DM layout in the strip; "Render counts" shows how many
 * times each row has rendered (React Profiler commits), so you can check that
 * a reaction, a flash or a streaming update renders one row only.
 *
 * Query parameters set the starting state for screenshots:
 *   lab-messages.html?theme=dark&dir=rtl&counts=1
 *
 * `globalThis.__messageLab` is the lab: `state()` reads the row menu (code
 * loaded, waiting, open, items with `aria-label` and `aria-keyshortcuts`),
 * the reaction chips (name, tooltip, pressed) and the picker anchor;
 * `menuDelay = ms` then `rightClick(rowId)` checks a request made before the
 * menu's code arrives; `warmMenu()`, `loadEmojiNames()`, `closePicker()`.
 */

import * as stylex from "@stylexjs/stylex"
import type { MessageRow } from "@inline/core-protocol"
import { useSignal } from "@inline/reactive/react"
import type { TimelineItem } from "@inline/timeline"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, Profiler, type ProfilerOnRenderCallback, StrictMode, useState } from "react"
import { createRoot } from "react-dom/client"
import {
  CONTENT_SLOT_SECTIONS,
  DaySeparatorRow,
  LoadingOlderRow,
  MessageActionsRegion,
  type MessageRowContext,
  type MessageRowHandlers,
  MessageRowSignalView,
  presentSender,
  slottedContent,
  UnreadLineRow,
} from "../../features/message"
import { createContentEnv, MessageContent } from "../../features/content"
import { STREAM_ROW_ID, userById, VIEWER_ID } from "./fixtures"
import { exposeLab, MessageLab } from "./lab-model"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

type Theme = "system" | "light" | "dark"
type Dir = "ltr" | "rtl"

const params = new URLSearchParams(location.search)
const initialTheme: Theme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: Dir = params.get("dir") === "rtl" ? "rtl" : "ltr"

const applyTheme = (theme: Theme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}
const applyDir = (dir: Dir) => {
  document.documentElement.dir = dir
}
applyTheme(initialTheme)
applyDir(initialDir)

const lab = new MessageLab()
exposeLab(lab)

// ---------------------------------------------------------------------------
// Render counts: one Profiler per row; the badge is written directly, so
// counting never renders anything.

const renderCounts = new Map<string, number>()
const badges = new Map<string, HTMLElement>()
let countsVisible = params.get("counts") === "1"

const onRowRender: ProfilerOnRenderCallback = (id) => {
  const count = (renderCounts.get(id) ?? 0) + 1
  renderCounts.set(id, count)
  const badge = badges.get(id)
  if (badge) badge.textContent = String(count)
}

const setCountsVisible = (visible: boolean) => {
  countsVisible = visible
  for (const badge of badges.values()) badge.hidden = !visible
}

const badgeRef = (id: string) => (element: HTMLElement | null) => {
  if (!element) return
  badges.set(id, element)
  element.textContent = String(renderCounts.get(id) ?? 0)
  element.hidden = !countsVisible
  return () => {
    if (badges.get(id) === element) badges.delete(id)
  }
}

// ---------------------------------------------------------------------------
// Row context: created once per DM setting, so rows keep their props.

const handlers: MessageRowHandlers = {
  onReplyClick: (_rowId, messageId) => {
    const target = lab.galleryItems.find((item) => item.kind === "message" && item.row.messageId === messageId)
    if (target?.kind !== "message") {
      lab.note(`Reply target ${messageId} is not loaded`)
      return
    }
    document.querySelector(`[data-message-row="${target.row.id}"]`)?.scrollIntoView({ block: "center" })
    lab.flash(target.row.id)
    lab.note(`Jumped to message ${messageId}`)
  },
  onReactionClick: (rowId, reaction) => {
    lab.toggleReaction(rowId, reaction.emoji)
    lab.note(`${reaction.mine ? "Removed" : "Added"} ${reaction.emoji}`)
  },
  onSenderClick: (userId) => lab.note(`Sender ${userId}`),
  onMention: (target) => lab.note(`Mention ${JSON.stringify(target)}`),
  onThreadRef: (target) => lab.note(`Thread ${JSON.stringify(target)}`),
  onBotCommand: (node) => lab.note(`Bot command ${node.command}`),
  onAppLink: (link) => lab.note(`App link ${link.href}`),
  onExternalLink: (link, event) => {
    event.preventDefault()
    lab.note(`External link ${link.href} (not followed in the lab)`)
  },
}

// The real content views (features/content), placed through the row's three
// slots. One environment and one source for the page, so rows keep their props.
const contentEnv = createContentEnv({
  handlers: {
    onAction: ({ button }) => {
      lab.note(`Button ${button.label}`)
      return new Promise((resolve) => setTimeout(resolve, 1200))
    },
    onOpenReplies: ({ chatId }) => lab.note(`Open replies in chat ${chatId}`),
    onOpenMedia: ({ key }) => lab.note(`Open media ${key}`),
    onExternalLink: (link, event) => {
      event.preventDefault()
      lab.note(`External link ${link.href} (not followed in the lab)`)
    },
    onCopyText: (text) => lab.note(`Copy ${text.slice(0, 40)}`),
  },
  names: {
    user: (id) => {
      const user = userById.get(id)
      if (!user) return undefined
      const sender = presentSender(user)
      return { name: sender.fullName, seed: sender.seed, ...(sender.photoUrl ? { photoUrl: sender.photoUrl } : {}) }
    },
    botName: (id) => (userById.get(id)?.username ?? undefined),
  },
})

const content = slottedContent((message: MessageRow, slot) => (
  <MessageContent message={message} env={contentEnv} sections={CONTENT_SLOT_SECTIONS[slot]} />
))

const highlightRangesFor = (rowId: string) => lab.find.rangesFor(rowId)

const contexts = new Map<boolean, MessageRowContext>()
const contextFor = (isDM: boolean): MessageRowContext => {
  let context = contexts.get(isDM)
  if (!context) {
    context = {
      times: lab.times,
      isDM,
      handlers,
      actions: lab.actions,
      content,
      highlightRangesFor,
      emojiEngine: lab.emoji.engine,
      viewerId: VIEWER_ID,
    }
    contexts.set(isDM, context)
  }
  return context
}

// ---------------------------------------------------------------------------
// Rows

/** One timeline item, the way the timeline view will place it. */
const Item = memo(function Item(props: { item: TimelineItem; context: MessageRowContext; scope?: string }) {
  const { item } = props
  if (item.kind === "day") return <DaySeparatorRow itemKey={item.key} label={lab.formatter.dayLabel(item.date).text} />
  if (item.kind === "unread") return <UnreadLineRow itemKey={item.key} />
  return (
    <LabRow
      rowId={item.row.id}
      firstInGroup={item.firstInGroup}
      lastInGroup={item.lastInGroup}
      itemKey={item.key}
      initial={item.row}
      context={props.context}
      probeId={props.scope ? `${props.scope}/${item.row.id}` : item.row.id}
    />
  )
})

const LabRow = memo(function LabRow(props: {
  rowId: string
  firstInGroup: boolean
  lastInGroup: boolean
  itemKey: string
  initial: MessageRow
  context: MessageRowContext
  /** Render-count key; the same row shown twice gets two. */
  probeId?: string
}) {
  const probeId = props.probeId ?? props.rowId
  const highlight = useSignal(lab.highlightFor(props.rowId))
  return (
    <div {...stylex.props(styles.probe)}>
      <Profiler id={probeId} onRender={onRowRender}>
        <MessageRowSignalView
          row={lab.row(props.rowId)}
          firstInGroup={props.firstInGroup}
          lastInGroup={props.lastInGroup}
          itemKey={props.itemKey}
          context={props.context}
          sender={lab.sender(props.initial)}
          reply={lab.reply(props.initial)}
          highlight={highlight}
        />
      </Profiler>
      <span ref={badgeRef(probeId)} aria-hidden="true" {...stylex.props(styles.badge)} />
    </div>
  )
})

function Gallery(props: { context: MessageRowContext }) {
  const loading = useSignal(lab.loadingOlder)
  return (
    <MessageActionsRegion controller={lab.actions} style={styles.list}>
      <LoadingOlderRow itemKey="loading" loading={loading} />
      {lab.galleryItems.map((item) => (
        <Item key={item.key} item={item} context={props.context} />
      ))}
    </MessageActionsRegion>
  )
}

function StreamingRow(props: { context: MessageRowContext }) {
  const streaming = useSignal(lab.streaming)
  return (
    <div>
      <div {...stylex.props(styles.controls)}>
        <button type="button" onClick={() => (streaming ? lab.stopStream() : lab.startStream(30))}>
          {streaming ? "Stop" : "Start"} streaming (30 updates/s)
        </button>
        <button type="button" onClick={() => lab.startStream(60)} disabled={streaming}>
          Start at 60/s
        </button>
        <button type="button" onClick={() => lab.resetStream()}>
          Reset
        </button>
      </div>
      <MessageActionsRegion controller={lab.actions} style={styles.list}>
        <LabRow
          rowId={STREAM_ROW_ID}
          firstInGroup
          lastInGroup
          itemKey={`m:${STREAM_ROW_ID}`}
          initial={lab.row(STREAM_ROW_ID).peek() as MessageRow}
          context={props.context}
        />
      </MessageActionsRegion>
    </div>
  )
}

/**
 * The same rows in a left-to-right and a right-to-left interface, whatever
 * the page's direction switch says. The panel's `dir` stands for the
 * interface; rows inherit it and only their text takes its own direction.
 */
function DirectionPanels(props: { context: MessageRowContext }) {
  return (
    <div {...stylex.props(styles.panels)}>
      {(["ltr", "rtl"] as const).map((dir) => (
        <div key={dir} dir={dir} {...stylex.props(styles.panel)}>
          <p {...stylex.props(styles.panelTitle)}>{dir === "ltr" ? "Left-to-right interface" : "Right-to-left interface"}</p>
          <MessageActionsRegion controller={lab.actions} style={styles.list}>
            {lab.directionItems.map((item) => (
              <Item key={item.key} item={item} context={props.context} scope={dir} />
            ))}
          </MessageActionsRegion>
        </div>
      ))}
    </div>
  )
}

function ContentRows(props: { context: MessageRowContext }) {
  return (
    <MessageActionsRegion controller={lab.actions} style={styles.list}>
      {lab.contentItems.map((item) => (
        <Item key={item.key} item={item} context={props.context} />
      ))}
    </MessageActionsRegion>
  )
}

function LongList(props: { context: MessageRowContext }) {
  return (
    <MessageActionsRegion controller={lab.actions} style={styles.scroller}>
      {lab.longItems.map((item) => (
        <Item key={item.key} item={item} context={props.context} />
      ))}
    </MessageActionsRegion>
  )
}

const revealRow = (rowId: string | undefined) => {
  if (rowId) document.querySelector(`[data-message-row="${rowId}"]`)?.scrollIntoView({ block: "center" })
}

/** Find in chat, as the find bar will drive it: the active match's row is highlighted. */
function FindBar() {
  const status = useSignal(lab.findStatus)
  return (
    <div role="search" {...stylex.props(styles.check)}>
      <input
        type="search"
        aria-label="Find in chat"
        placeholder="Find (try “deploy”)"
        onInput={(event) => revealRow(lab.search(event.currentTarget.value))}
        onKeyDown={(event) => {
          if (event.key !== "Enter") return
          event.preventDefault()
          revealRow(lab.nextMatch(event.shiftKey ? -1 : 1))
        }}
      />
      <button type="button" aria-label="Previous match" onClick={() => revealRow(lab.nextMatch(-1))}>
        ↑
      </button>
      <button type="button" aria-label="Next match" onClick={() => revealRow(lab.nextMatch(1))}>
        ↓
      </button>
      <output aria-live="polite">{status}</output>
    </div>
  )
}

function Log() {
  const text = useSignal(lab.log)
  return (
    <output aria-live="polite" {...stylex.props(styles.log)}>
      {text}
    </output>
  )
}

// ---------------------------------------------------------------------------
// Page

const randomLongRow = (): string | undefined => {
  const messages = lab.longItems.filter((item) => item.kind === "message")
  const item = messages[Math.floor(Math.random() * messages.length)]
  return item?.kind === "message" ? item.row.id : undefined
}

function Lab() {
  const [theme, setTheme] = useState<Theme>(initialTheme)
  const [dir, setDir] = useState<Dir>(initialDir)
  const isDM = useSignal(lab.isDM)
  const loading = useSignal(lab.loadingOlder)
  const context = contextFor(isDM)
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>Message lab</h1>
        <Segmented
          label="Appearance"
          value={theme}
          options={["system", "light", "dark"]}
          onChange={(next) => {
            applyTheme(next)
            setTheme(next)
          }}
        />
        <Segmented
          label="Direction"
          value={dir}
          options={["ltr", "rtl"]}
          onChange={(next) => {
            applyDir(next)
            setDir(next)
          }}
        />
        <label {...stylex.props(styles.check)}>
          <input type="checkbox" checked={isDM} onChange={(event) => lab.isDM.set(event.currentTarget.checked)} />
          DM chat
        </label>
        <label {...stylex.props(styles.check)}>
          <input
            type="checkbox"
            defaultChecked={countsVisible}
            onChange={(event) => setCountsVisible(event.currentTarget.checked)}
          />
          Render counts
        </label>
        <label {...stylex.props(styles.check)}>
          <input type="checkbox" checked={loading} onChange={(event) => lab.loadingOlder.set(event.currentTarget.checked)} />
          Loading older
        </label>
        <button
          type="button"
          onClick={() => {
            const id = randomLongRow()
            if (!id) return
            lab.toggleReaction(id, "🔥")
            document.querySelector(`[data-message-row="${id}"]`)?.scrollIntoView({ block: "center" })
            lab.flash(id)
            lab.note(`Toggled 🔥 on ${id} and flashed it: only that row renders`)
          }}
        >
          React and flash a random row
        </button>
        <FindBar />
        <Log />
      </header>
      <main {...stylex.props(styles.main)}>
        <section aria-labelledby="gallery-title" {...stylex.props(styles.section)}>
          <h2 id="gallery-title" {...stylex.props(styles.sectionTitle)}>
            Gallery
          </h2>
          <p {...stylex.props(styles.hint)}>
            Runs of several senders, own and others, every entity, long words and code lines, right to left and mixed
            text, emoji-only, each delivery state, edited, replies, reactions, unsupported content, the media slot and
            the separators. Right-click a message for its menu; links keep the browser&apos;s menu.
          </p>
          <Gallery context={context} />
        </section>
        <section aria-labelledby="content-title" {...stylex.props(styles.section)}>
          <h2 id="content-title" {...stylex.props(styles.sectionTitle)}>
            Content
          </h2>
          <p {...stylex.props(styles.hint)}>
            The real content views in the row&apos;s slots: a photo above its caption, a link preview and &quot;Sent
            via&quot; below the text, bot buttons and a reply summary under the bubble, a sticker and a PNG without a
            caption with no bubble, and rich blocks in place of the text (it must appear once). Media has no URL here,
            so boxes show their reserved size.
          </p>
          <ContentRows context={context} />
        </section>
        <section aria-labelledby="direction-title" {...stylex.props(styles.section)}>
          <h2 id="direction-title" {...stylex.props(styles.sectionTitle)}>
            Direction
          </h2>
          <p {...stylex.props(styles.hint)}>
            Arabic from another sender must sit at the interface&apos;s start with its avatar and name there too;
            your own messages at its end, in either script. Only the text inside each bubble takes its own direction.
          </p>
          <DirectionPanels context={context} />
        </section>
        <section aria-labelledby="stream-title" {...stylex.props(styles.section)}>
          <h2 id="stream-title" {...stylex.props(styles.sectionTitle)}>
            Streaming
          </h2>
          <StreamingRow context={context} />
        </section>
        <section aria-labelledby="long-title" {...stylex.props(styles.section)}>
          <h2 id="long-title" {...stylex.props(styles.sectionTitle)}>
            500 rows
          </h2>
          <LongList context={context} />
        </section>
      </main>
    </div>
  )
}

/** Plain radio buttons, so the lab does not depend on the kit for its own chrome. */
function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.check)}>
          <input
            type="radio"
            name={props.label}
            value={option}
            checked={props.value === option}
            onChange={() => props.onChange(option)}
          />
          {option}
        </label>
      ))}
    </fieldset>
  )
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    overflow: "auto",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: {
    position: "sticky",
    top: 0,
    zIndex: 2,
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.lg,
    paddingBlock: space.md,
    paddingInline: space.xl,
    backgroundColor: color.sidebarBackground,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  segmented: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    margin: 0,
    padding: 0,
    borderStyle: "none",
  },
  legend: { float: "inline-start", marginInlineEnd: space.sm, color: color.secondaryLabel },
  check: { display: "inline-flex", alignItems: "center", gap: space.xs },
  log: {
    flexBasis: "100%",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  main: {
    display: "flex",
    flexDirection: "column",
    gap: space.huge,
    paddingBlock: space.xl,
    maxInlineSize: "960px",
    marginInline: "auto",
  },
  section: { display: "flex", flexDirection: "column", gap: space.md },
  sectionTitle: { margin: 0, paddingInline: space.xl, fontSize: font.sizeTitle2, fontWeight: font.weightSemibold },
  hint: { margin: 0, paddingInline: space.xl, color: color.secondaryLabel },
  controls: { display: "flex", gap: space.md, paddingInline: space.xl, paddingBlockEnd: space.md },
  list: {
    paddingBlockStart: "14px",
    paddingBlockEnd: "10px",
    borderBlockWidth: "1px",
    borderBlockStyle: "solid",
    borderBlockColor: color.separator,
  },
  scroller: {
    blockSize: "640px",
    overflowY: "auto",
    overflowAnchor: "none",
    paddingBlockStart: "14px",
    paddingBlockEnd: "10px",
    borderBlockWidth: "1px",
    borderBlockStyle: "solid",
    borderBlockColor: color.separator,
  },
  probe: { position: "relative" },
  panels: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
    gap: space.lg,
  },
  panel: { minInlineSize: 0 },
  panelTitle: { margin: 0, paddingInline: space.xl, paddingBlockEnd: space.xs, color: color.secondaryLabel },
  badge: {
    position: "absolute",
    insetBlockStart: "2px",
    insetInlineStart: "2px",
    zIndex: 1,
    minInlineSize: "16px",
    paddingInline: "4px",
    boxSizing: "border-box",
    borderRadius: radius.pill,
    backgroundColor: color.orange,
    color: "#000000",
    fontSize: "10px",
    lineHeight: "14px",
    textAlign: "center",
    fontVariantNumeric: "tabular-nums",
    pointerEvents: "none",
    userSelect: "none",
  },
})

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(
    <StrictMode>
      <Lab />
    </StrictMode>,
  )
}
