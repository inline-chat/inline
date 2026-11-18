/**
 * Composer lab: `ComposerView` over a real composer model whose `send` and
 * `saveDraft` are fakes (lab.ts). The strip chooses the send outcome, the
 * mention source, reply and edit state, the send key, appearance, direction
 * and width; the panel prints the document, the last send request and the
 * saved draft, which are also on `globalThis.__composerLab` as plain data
 * (`globalThis.__composerLabControls` drives the strip from automation:
 * also `payloadForSelection`, `pasteInternal(raw, text)` (cross-tab rich
 * paste: copy a payload in one tab, paste it in another), `forgedPayload`,
 * `pasteHtml`, `selectAll`).
 *
 * Query parameters set the starting state for screenshots:
 *   lab-composer.html?theme=dark&dir=rtl&width=narrow&sendKey=modEnter
 */

import type { SendKey } from "@inline/composer"
import { useElement, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { ComposerView } from "../../features/composer"
import {
  applyDir,
  applyTheme,
  ComposerLab,
  SEND_MODE_LABELS,
  type LabDir,
  type LabTheme,
  type LabWidth,
  type MentionSource,
  type SendMode,
} from "./lab"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const lab = new ComposerLab()
lab.expose()
lab.installTypeAnywhere(document)

const params = new URLSearchParams(location.search)
const initialTheme: LabTheme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: LabDir = params.get("dir") === "rtl" ? "rtl" : "ltr"
lab.theme.set(initialTheme)
lab.dir.set(initialDir)
lab.width.set(params.get("width") === "narrow" ? "narrow" : "wide")
lab.sendKey.set(params.get("sendKey") === "modEnter" ? "modEnter" : "enter")
applyTheme(initialTheme)
applyDir(initialDir)

function Lab() {
  const width = useSignal(lab.width)
  const placeholder = useSignal(lab.placeholder)
  const spellcheck = useSignal(lab.spellcheck)
  const listRef = useElement(lab.messageList)
  return (
    <div {...stylex.props(styles.page)}>
      <ControlStrip />
      <main {...stylex.props(styles.main)}>
        <section aria-label="Chat" {...stylex.props(styles.stage, width === "narrow" && styles.stageNarrow)}>
          <div ref={listRef} tabIndex={-1} aria-label="Messages (stand-in)" {...stylex.props(styles.messages)}>
            <p {...stylex.props(styles.message)}>Ada Lovelace: The engine might compose elaborate pieces of music.</p>
            <p {...stylex.props(styles.message)}>You: Shipping the composer lab today</p>
            <p dir="auto" {...stylex.props(styles.message)}>مریم میرزاخانی: سلام، فردا جلسه داریم؟</p>
            <p {...stylex.props(styles.note)}>
              Focus lands here on Escape in an empty composer. Type anywhere outside a field to focus the composer.
            </p>
          </div>
          <div {...stylex.props(styles.composerSlot)}>
            <ComposerView model={lab.model} placeholder={placeholder} spellcheck={spellcheck} />
          </div>
        </section>
        <StatePanel />
      </main>
    </div>
  )
}

function ControlStrip() {
  const theme = useSignal(lab.theme)
  const dir = useSignal(lab.dir)
  const width = useSignal(lab.width)
  const sendKey = useSignal(lab.sendKey)
  const sendMode = useSignal(lab.sendMode)
  const delay = useSignal(lab.delayMs)
  const mentions = useSignal(lab.mentionSource)
  const others = useSignal(lab.otherSources)
  const spellcheck = useSignal(lab.spellcheck)
  const placeholder = useSignal(lab.placeholder)
  const replying = useSignal(lab.model.composer.reply) !== null
  const editing = useSignal(lab.model.composer.editing) !== null
  const held = useSignal(lab.held) !== null
  return (
    <header {...stylex.props(styles.strip)}>
      <h1 {...stylex.props(styles.title)}>Composer lab</h1>
      <Segmented<LabTheme>
        label="Appearance"
        value={theme}
        options={["system", "light", "dark"]}
        onChange={(next) => {
          applyTheme(next)
          lab.theme.set(next)
        }}
      />
      <Segmented<LabDir>
        label="Direction"
        value={dir}
        options={["ltr", "rtl"]}
        onChange={(next) => {
          applyDir(next)
          lab.dir.set(next)
        }}
      />
      <Segmented<LabWidth> label="Width" value={width} options={["wide", "narrow"]} onChange={(next) => lab.width.set(next)} />
      <Segmented<SendKey> label="Send key" value={sendKey} options={["enter", "modEnter"]} onChange={(next) => lab.sendKey.set(next)} />
      <Segmented<SendMode>
        label="Send outcome"
        value={sendMode}
        options={["accept", "reject-storage", "uncertain", "hold"]}
        labels={SEND_MODE_LABELS}
        onChange={(next) => lab.sendMode.set(next)}
      />
      <label {...stylex.props(styles.field)}>
        Delay (ms)
        <input
          type="number"
          min={0}
          step={100}
          value={delay}
          onChange={(event) => lab.delayMs.set(Math.max(0, Number(event.currentTarget.value) || 0))}
          {...stylex.props(styles.number)}
        />
      </label>
      <button type="button" disabled={!held} onClick={() => lab.settleHeld({ status: "accepted" })}>
        Accept held send
      </button>
      <button type="button" disabled={!held} onClick={() => lab.settleHeld({ status: "rejected", reason: "storageFull" })}>
        Reject held send
      </button>
      <Segmented<MentionSource>
        label="Mentions"
        value={mentions}
        options={["instant", "delayed", "none"]}
        onChange={(next) => lab.mentionSource.set(next)}
      />
      <Check label="Emoji and commands" checked={others} onChange={(next) => lab.otherSources.set(next)} />
      <Check label="Replying" checked={replying} onChange={(next) => lab.setReply(next)} />
      <Check label="Editing" checked={editing} onChange={(next) => lab.setEditing(next)} />
      <Check label="Spell check" checked={spellcheck} onChange={(next) => lab.spellcheck.set(next)} />
      <label {...stylex.props(styles.field)}>
        Placeholder
        <input value={placeholder} onChange={(event) => lab.placeholder.set(event.currentTarget.value)} {...stylex.props(styles.text)} />
      </label>
      <button type="button" onClick={() => lab.loadSampleDraft()}>
        Restore sample draft
      </button>
      <button type="button" onClick={() => lab.model.focus()}>
        Focus composer
      </button>
      <button type="button" onClick={() => lab.pasteInternal(lab.forgedPayload(), "@Ada Lovelace")}>
        Paste forged mention
      </button>
      <button type="button" onClick={() => lab.pasteHtml()}>
        Paste HTML (late if not loaded)
      </button>
    </header>
  )
}

function StatePanel() {
  const snapshot = useSignal(lab.snapshot)
  const { doc, lastSend, savedDraft, events, ...state } = snapshot
  return (
    <aside aria-label="Composer state" {...stylex.props(styles.panel)}>
      <h2 {...stylex.props(styles.panelTitle)}>Document</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(doc, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>State</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(state, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Last send request</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(lastSend, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Saved draft</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(savedDraft, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Events</h2>
      <pre {...stylex.props(styles.pre)}>{events.join("\n")}</pre>
    </aside>
  )
}

/** The lab's own switchers: plain radios and checkboxes, so the lab does not depend on the kit it shows. */
function Segmented<T extends string>(props: {
  label: string
  value: T
  options: readonly T[]
  labels?: Partial<Record<T, string>>
  onChange: (value: T) => void
}) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.segment)}>
          <input type="radio" name={props.label} value={option} checked={props.value === option} onChange={() => props.onChange(option)} />
          {props.labels?.[option] ?? option}
        </label>
      ))}
    </fieldset>
  )
}

function Check(props: { label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return (
    <label {...stylex.props(styles.segment)}>
      <input type="checkbox" checked={props.checked} onChange={(event) => props.onChange(event.currentTarget.checked)} />
      {props.label}
    </label>
  )
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    display: "flex",
    flexDirection: "column",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  strip: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.md,
    paddingBlock: space.md,
    paddingInline: space.xl,
    backgroundColor: color.sidebarBackground,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  main: {
    flexGrow: 1,
    minBlockSize: 0,
    display: "flex",
    gap: space.xl,
    padding: space.xl,
  },
  stage: {
    flexGrow: 1,
    minInlineSize: 0,
    display: "flex",
    flexDirection: "column",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
    overflow: "hidden",
  },
  stageNarrow: { flexGrow: 0, inlineSize: "360px" },
  messages: {
    flexGrow: 1,
    minBlockSize: 0,
    overflowY: "auto",
    padding: space.xl,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "-2px",
  },
  message: { margin: 0, marginBlockEnd: space.md },
  note: { margin: 0, marginBlockStart: space.xl, color: color.secondaryLabel, fontSize: font.sizeCallout },
  composerSlot: { paddingInline: space.lg, paddingBlockEnd: space.lg },
  panel: {
    flexBasis: "380px",
    flexShrink: 0,
    overflowY: "auto",
    padding: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
  },
  panelTitle: { margin: 0, marginBlock: space.sm, fontSize: font.sizeCallout, fontWeight: font.weightSemibold },
  pre: {
    margin: 0,
    padding: space.sm,
    fontFamily: font.familyMono,
    fontSize: font.sizeSubheadline,
    whiteSpace: "pre-wrap",
    overflowWrap: "anywhere",
    backgroundColor: color.textBackground,
    borderRadius: radius.control,
  },
  segmented: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.sm,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.sm, color: color.secondaryLabel },
  segment: { display: "inline-flex", alignItems: "center", gap: space.xxs },
  field: { display: "inline-flex", alignItems: "center", gap: space.sm, color: color.secondaryLabel },
  number: { inlineSize: "72px" },
  text: { inlineSize: "140px" },
})

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(
    <StrictMode>
      <Lab />
    </StrictMode>,
  )
}
