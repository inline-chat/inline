/**
 * Chat info lab: the real `ChatInfoPane` over a scripted core with several
 * hundred generated people in mixed scripts; a real composer whose `@`
 * suggestions come from the mention model; the chat's typing line; and the
 * outgoing compose actions the composer reports. The strip switches the
 * participants fallback (private, subthread, reply, public, direct, bot), the
 * intent outcome, offline, incoming typing from one, two or many people,
 * appearance and direction.
 *
 * Driving it: `globalThis.__chatInfoLab` is the state as plain data (a
 * getter, always current) and `globalThis.__chatInfoLabControl` the
 * operations (see `control()` in lab.ts).
 *
 * Query parameters set the starting state for screenshots:
 *   lab-chatinfo.html?scenario=public&theme=dark&dir=rtl&narrow=1
 */

import { useSignal } from "@inline/reactive/react"
import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { memoryAppearanceStorage, type Appearance } from "@inline/ui/theme"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { ChatInfoPane } from "../../features/chat-info"
import type { IntentMode } from "../../features/chat-info/testing"
import { ComposerView } from "../../features/composer"
import { TypingLine } from "../../features/typing"
import { ChatInfoLab, INTENT_MODES, SCENARIO_LABELS, SCENARIOS, type LabDir, type Scenario } from "./lab"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const params = new URLSearchParams(location.search)
const appearance = startDocumentAppearance({ storage: memoryAppearanceStorage(), writeBootRecord: false })
const theme = params.get("theme")
appearance.setAppearance(theme === "dark" || theme === "light" ? theme : "system")

const lab = new ChatInfoLab()
const scenario = params.get("scenario")
if (scenario && (SCENARIOS as readonly string[]).includes(scenario)) lab.setScenario(scenario as Scenario)
lab.setDir(params.get("dir") === "rtl" ? "rtl" : "ltr")
lab.narrow.set(params.get("narrow") === "1")
lab.expose()

function Lab() {
  const models = useSignal(lab.models)
  const narrow = useSignal(lab.narrow)
  const typing = useSignal(models.typing.status)
  return (
    <div {...stylex.props(styles.page)}>
      <ControlStrip />
      <main {...stylex.props(styles.main)}>
        <section data-lab-stage="" aria-label="Chat info pane" {...stylex.props(styles.stage, narrow && styles.stageNarrow)}>
          <ChatInfoPane key={models.info.chatId} model={models.info} />
        </section>
        <section aria-label="Composer and typing" {...stylex.props(styles.side)}>
          <h2 {...stylex.props(styles.panelTitle)}>Typing line</h2>
          <p {...stylex.props(styles.typingRow)} data-lab-typing="">
            {typing ? <TypingLine status={typing} /> : <span {...stylex.props(styles.muted)}>Nobody is typing</span>}
          </p>
          <h2 {...stylex.props(styles.panelTitle)}>Composer (type @ for mentions)</h2>
          <div {...stylex.props(styles.composer)}>
            <ComposerView key={models.info.chatId} model={models.composer} placeholder="Message" />
          </div>
          <StatePanel />
        </section>
      </main>
    </div>
  )
}

function ControlStrip() {
  const scenario = useSignal(lab.scenario)
  const settings = useSignal(appearance.settings)
  return (
    <header aria-label="Lab controls" {...stylex.props(styles.strip)}>
      <h1 {...stylex.props(styles.title)}>Chat info lab</h1>
      <label {...stylex.props(styles.segment)}>
        Chat
        <select value={scenario} onChange={(event) => lab.setScenario(event.currentTarget.value as Scenario)}>
          {SCENARIOS.map((id) => (
            <option key={id} value={id}>
              {SCENARIO_LABELS[id]}
            </option>
          ))}
        </select>
      </label>
      <label {...stylex.props(styles.segment)}>
        Outcome
        <select value={useSignal(lab.intentMode)} onChange={(event) => lab.setIntentMode(event.currentTarget.value as IntentMode)}>
          {INTENT_MODES.map((mode) => (
            <option key={mode} value={mode}>
              {mode}
            </option>
          ))}
        </select>
      </label>
      <button type="button" onClick={() => lab.settleHeld("confirmed")}>
        Confirm held
      </button>
      <button type="button" onClick={() => lab.settleHeld("uncertain")}>
        Held → uncertain
      </button>
      <Check label="Offline" checked={useSignal(lab.offline)} onChange={(next) => lab.offline.set(next)} />
      <span {...stylex.props(styles.group)}>
        Typing:
        <button type="button" onClick={() => lab.typing(1)}>
          1
        </button>
        <button type="button" onClick={() => lab.typing(2)}>
          2
        </button>
        <button type="button" onClick={() => lab.typing(3)}>
          3
        </button>
        <button type="button" onClick={() => lab.typing(7)}>
          7
        </button>
        <button type="button" onClick={() => lab.typing(1, "uploadingPhoto")}>
          photo
        </button>
        <button type="button" onClick={() => lab.typing(1, "recordingVoice")}>
          voice
        </button>
        <button type="button" onClick={() => lab.typing(1, "working")}>
          working
        </button>
        <button type="button" onClick={() => lab.clearTyping()}>
          clear
        </button>
      </span>
      <button type="button" onClick={() => lab.speak(1 + Math.floor(Math.random() * 40))}>
        Someone speaks
      </button>
      <button type="button" onClick={() => lab.rename(2)}>
        Rename one
      </button>
      <button type="button" onClick={() => lab.restartBig()}>
        Big list: reload
      </button>
      <Segmented<Appearance> label="Theme" value={settings.appearance} options={["light", "dark", "system"]} onChange={(next) => appearance.setAppearance(next)} />
      <Segmented<LabDir> label="Direction" value={useSignal(lab.dir)} options={["ltr", "rtl"]} onChange={(next) => lab.setDir(next)} />
      <Check label="Narrow" checked={useSignal(lab.narrow)} onChange={(next) => lab.narrow.set(next)} />
    </header>
  )
}

function StatePanel() {
  const snapshot = useSignal(lab.snapshot)
  const { events, ...rest } = snapshot
  return (
    <div {...stylex.props(styles.state)}>
      <h2 {...stylex.props(styles.panelTitle)}>State</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(rest, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Events</h2>
      <pre {...stylex.props(styles.pre)}>{events.join("\n")}</pre>
    </div>
  )
}

/** The lab's own switchers: plain radios and checkboxes, so the lab does not depend on the kit it shows. */
function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.segment)}>
          <input type="radio" name={`lab-${props.label}`} value={option} checked={props.value === option} onChange={() => props.onChange(option)} />
          {option}
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
  group: { display: "inline-flex", alignItems: "center", gap: space.xs },
  main: { flexGrow: 1, minBlockSize: 0, display: "flex", gap: space.xl, padding: space.xl, flexWrap: "wrap" },
  stage: {
    flexGrow: 1,
    flexBasis: "420px",
    minInlineSize: 0,
    maxBlockSize: "100%",
    overflowY: "auto",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
  },
  stageNarrow: { flexGrow: 0, flexBasis: "320px", inlineSize: "320px" },
  side: {
    flexBasis: "380px",
    flexShrink: 0,
    minInlineSize: 0,
    maxBlockSize: "100%",
    overflowY: "auto",
    display: "flex",
    flexDirection: "column",
    gap: space.md,
  },
  composer: { display: "flex", flexDirection: "column" },
  typingRow: { margin: 0, minBlockSize: "1.5em" },
  muted: { color: color.secondaryLabel, fontSize: font.sizeCallout },
  state: { display: "flex", flexDirection: "column", gap: space.sm },
  panelTitle: { margin: 0, fontSize: font.sizeSubheadline, fontWeight: font.weightSemibold, color: color.secondaryLabel, textTransform: "uppercase" },
  pre: { margin: 0, fontFamily: font.familyMono, fontSize: font.sizeCaption, whiteSpace: "pre-wrap", overflowWrap: "anywhere" },
  segmented: { display: "inline-flex", alignItems: "center", gap: space.xs, borderWidth: 0, margin: 0, padding: 0 },
  legend: { float: "inline-start", paddingInlineEnd: space.xs },
  segment: { display: "inline-flex", alignItems: "center", gap: space.xxs },
})

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(
    <StrictMode>
      <Lab />
    </StrictMode>,
  )
}
