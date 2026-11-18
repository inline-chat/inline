/**
 * Settings lab: `SettingsView` over a real `AppearanceController` bound to
 * this document (in-memory, so nothing persists), the fake platform with
 * lab-controlled notifications, storage and updates, an in-memory
 * preferences store with a second store as "another tab", and stubbed
 * account data. The strip switches every state; Back and Forward act like the
 * workspace's history. The panel prints the state.
 *
 * Driving it: `globalThis.__settingsLab` is the state as plain data (a
 * getter, always current) and `globalThis.__settingsLabControl` the
 * operations (see `control()` in lab.ts).
 *
 * Query parameters set the starting state for screenshots:
 *   lab-settings.html?page=appearance&theme=dark&dir=rtl&width=narrow&os=windows&permission=denied&storage=notPersistent&update=ready
 */

import { useSignal } from "@inline/reactive/react"
import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { memoryAppearanceStorage, THEME_IDS, THEME_TITLES, type Appearance, type ThemeId } from "@inline/ui/theme"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { OS } from "@inline/view"
import * as stylex from "@stylexjs/stylex"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { SettingsView } from "../../features/settings"
import { labParams, SettingsLab, type LabDir, type LabEstimate, type LabPermission, type LabStorage, type LabUpdate } from "./lab"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

// First: the document's appearance, in this task, before React renders. In memory, so the lab never changes the app's.
const appearance = startDocumentAppearance({ storage: memoryAppearanceStorage(), writeBootRecord: false })
const params = labParams(location.search)
appearance.setAppearance(params.theme)

const lab = new SettingsLab(appearance)
lab.os.set(params.os)
lab.setPermission(params.permission)
lab.setStorage(params.storage)
lab.setUpdate(params.update)
lab.narrow.set(params.width === "narrow")
lab.setDir(params.dir)
if (params.page) lab.history.set({ entries: [params.page], index: 0 })
lab.expose()

function Lab() {
  const page = useSignal(lab.page)
  const platform = useSignal(lab.platform)
  const prompt = useSignal(lab.prompt)
  const shortcuts = useSignal(lab.shortcuts)
  const account = useSignal(lab.account)
  const pendingCount = useSignal(lab.pendingCount)
  const mediaHandler = useSignal(lab.mediaHandler)
  const narrow = useSignal(lab.narrow)
  return (
    <div {...stylex.props(styles.page)}>
      <ControlStrip />
      <div {...stylex.props(styles.main)}>
        <div data-lab-stage="" {...stylex.props(styles.stage, narrow && styles.stageNarrow)}>
          <SettingsView
            page={page}
            onNavigate={lab.navigate}
            appearance={lab.appearance}
            platform={platform}
            preferences={lab.preferences}
            {...(account ? { account } : {})}
            pendingCount={pendingCount}
            shortcuts={shortcuts}
            notificationPrompt={prompt}
            buildId="web-2026.11.17-lab"
            {...(mediaHandler ? { onClearCachedMedia: lab.onClearCachedMedia } : {})}
          />
        </div>
        <StatePanel />
      </div>
    </div>
  )
}

function ControlStrip() {
  const history = useSignal(lab.history)
  const settings = useSignal(lab.appearance.settings)
  return (
    <header aria-label="Lab controls" {...stylex.props(styles.strip)}>
      <h1 {...stylex.props(styles.title)}>Settings lab</h1>
      <button type="button" disabled={history.index === 0} onClick={() => lab.back()}>
        Back
      </button>
      <button type="button" disabled={history.index >= history.entries.length - 1} onClick={() => lab.forward()}>
        Forward
      </button>
      <Segmented<Appearance>
        label="Theme"
        value={settings.appearance}
        options={["light", "dark", "system"]}
        onChange={(next) => lab.setAppearance(next)}
      />
      <label {...stylex.props(styles.segment)}>
        Palette
        <select value={settings.theme} onChange={(event) => lab.setTheme(event.currentTarget.value as ThemeId)}>
          {THEME_IDS.map((id) => (
            <option key={id} value={id}>
              {THEME_TITLES[id]}
            </option>
          ))}
        </select>
      </label>
      <Segmented<LabDir> label="Direction" value={useSignal(lab.dir)} options={["ltr", "rtl"]} onChange={(next) => lab.setDir(next)} />
      <Check label="Narrow" checked={useSignal(lab.narrow)} onChange={(next) => lab.narrow.set(next)} />
      <button type="button" onClick={() => lab.showNarrowAppearance()}>
        Appearance, narrow
      </button>
      <Segmented<OS> label="OS" value={useSignal(lab.os)} options={["mac", "windows", "linux"]} onChange={(next) => lab.os.set(next)} />
      <Segmented<LabPermission>
        label="Permission"
        value={useSignal(lab.permission)}
        options={["default", "granted", "denied", "unavailable"]}
        onChange={(next) => lab.setPermission(next)}
      />
      <Segmented<LabStorage>
        label="Storage"
        value={useSignal(lab.storage)}
        options={["persistent", "notPersistent", "unknown", "unavailable"]}
        onChange={(next) => lab.setStorage(next)}
      />
      <Segmented<LabEstimate>
        label="Usage"
        value={useSignal(lab.estimate)}
        options={["measuring", "small", "large"]}
        onChange={(next) => lab.setEstimate(next)}
      />
      <Segmented<LabUpdate>
        label="Update"
        value={useSignal(lab.update)}
        options={["none", "available", "ready"]}
        onChange={(next) => lab.setUpdate(next)}
      />
      <Check label="Signed in" checked={useSignal(lab.signedIn)} onChange={(next) => lab.signedIn.set(next)} />
      <Check label="Account loading" checked={useSignal(lab.accountLoading)} onChange={(next) => lab.setAccountLoading(next)} />
      <Segmented<"0" | "1" | "3">
        label="Unsent"
        value={String(useSignal(lab.pendingCount)) as "0" | "1" | "3"}
        options={["0", "1", "3"]}
        onChange={(next) => lab.pendingCount.set(Number(next))}
      />
      <Check label="Media cache handler" checked={useSignal(lab.mediaHandler)} onChange={(next) => lab.mediaHandler.set(next)} />
      <button type="button" onClick={() => lab.otherTabUpdate({ sendKey: lab.otherTab.sendKey.peek() === "enter" ? "modEnter" : "enter" })}>
        Other tab: toggle send key
      </button>
      <button type="button" onClick={() => lab.otherTabUpdate({ spellCheck: !lab.otherTab.spellCheck.peek() })}>
        Other tab: toggle spell check
      </button>
    </header>
  )
}

function StatePanel() {
  const snapshot = useSignal(lab.snapshot)
  const { events, preferences, otherTabPreferences, appearance: appearanceSettings, ...rest } = snapshot
  return (
    <aside aria-label="Lab state" {...stylex.props(styles.panel)}>
      <h2 {...stylex.props(styles.panelTitle)}>Preferences (this tab, other tab)</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify({ preferences, otherTabPreferences }, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>State</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(rest, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Appearance</h2>
      <pre {...stylex.props(styles.pre)}>{JSON.stringify(appearanceSettings, null, 2)}</pre>
      <h2 {...stylex.props(styles.panelTitle)}>Events</h2>
      <pre {...stylex.props(styles.pre)}>{events.join("\n")}</pre>
    </aside>
  )
}

/** The lab's own switchers: plain radios and checkboxes, so the lab does not depend on the kit it shows. */
function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.segment)}>
          <input
            type="radio"
            name={`lab-${props.label}`}
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
  main: { flexGrow: 1, minBlockSize: 0, display: "flex", gap: space.xl, padding: space.xl },
  stage: {
    flexGrow: 1,
    minInlineSize: 0,
    display: "flex",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
    overflow: "hidden",
  },
  stageNarrow: { flexGrow: 0, inlineSize: "400px" },
  panel: {
    inlineSize: "320px",
    flexShrink: 0,
    overflowY: "auto",
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
  },
  panelTitle: { margin: 0, fontSize: font.sizeCallout, fontWeight: font.weightSemibold, color: color.secondaryLabel },
  pre: {
    margin: 0,
    padding: space.md,
    fontFamily: font.familyMono,
    fontSize: font.sizeFootnote,
    whiteSpace: "pre-wrap",
    wordBreak: "break-word",
    backgroundColor: color.textBackground,
    borderRadius: radius.control,
  },
  segmented: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.sm,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.sm, padding: 0, color: color.secondaryLabel },
  segment: { display: "inline-flex", alignItems: "center", gap: space.xs },
})

const container = document.getElementById("root")
if (container) {
  createRoot(container).render(
    <StrictMode>
      <Lab />
    </StrictMode>,
  )
}
