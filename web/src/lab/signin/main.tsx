/**
 * Sign-in lab: `SignInScreen` over a real sign-in model whose `fetch` is a
 * scripted server (lab-server.ts). The strip chooses the server's next answer
 * and the appearance; the panel prints the model's state, which is also on
 * `globalThis.__signinLab` as plain data.
 *
 * Query parameters set the starting state for screenshots:
 *   lab-signin.html?theme=dark&dir=rtl&width=320
 */

import { useModel, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { SignInScreen } from "../../features/signin"
import { LAB_ANSWER_LABELS, LAB_ANSWERS, type LabAnswer } from "./lab-server"
import {
  applyDir,
  applyTheme,
  exposeLab,
  SignInLab,
  type LabDir,
  type LabTheme,
  type LabWidth,
} from "./lab-session"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const lab = new SignInLab()
exposeLab(lab)

const params = new URLSearchParams(location.search)
const initialTheme: LabTheme =
  params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: LabDir = params.get("dir") === "rtl" ? "rtl" : "ltr"
lab.theme.set(initialTheme)
lab.dir.set(initialDir)
lab.width.set(params.get("width") === "320" ? "320" : "auto")
applyTheme(initialTheme)
applyDir(initialDir)

function Lab() {
  const generation = useSignal(lab.generation)
  const model = useModel(() => lab.createModel(), [generation])
  const providersEnabled = useSignal(lab.providersEnabled)
  const autoSubmitLength = useSignal(lab.autoSubmitLength)
  const width = useSignal(lab.width)
  return (
    <div {...stylex.props(styles.page)}>
      <ControlStrip />
      <main {...stylex.props(styles.main)}>
        <div {...stylex.props(styles.stage, width === "320" && styles.stageNarrow)}>
          <SignInScreen
            model={model}
            enabledProviders={providersEnabled ? ["google", "apple"] : []}
            navigate={lab.navigate}
            codeLength={autoSubmitLength ?? undefined}
          />
        </div>
        <StatePanel model={model} />
      </main>
    </div>
  )
}

function ControlStrip() {
  const next = useSignal(lab.server.next)
  const newAccount = useSignal(lab.server.newAccount)
  const providersEnabled = useSignal(lab.providersEnabled)
  const autoSubmitLength = useSignal(lab.autoSubmitLength)
  const theme = useSignal(lab.theme)
  const dir = useSignal(lab.dir)
  const width = useSignal(lab.width)
  return (
    <header {...stylex.props(styles.strip)}>
      <h1 {...stylex.props(styles.title)}>Sign-in lab</h1>
      <Segmented<LabAnswer>
        label="Next answer"
        value={next}
        options={LAB_ANSWERS}
        labels={LAB_ANSWER_LABELS}
        onChange={(answer) => lab.setNext(answer)}
      />
      <label {...stylex.props(styles.check)}>
        <input type="checkbox" checked={newAccount} onChange={(event) => lab.server.newAccount.set(event.currentTarget.checked)} />
        New account (needs setup)
      </label>
      <label {...stylex.props(styles.check)}>
        <input
          type="checkbox"
          checked={autoSubmitLength !== null}
          onChange={(event) => lab.autoSubmitLength.set(event.currentTarget.checked ? 6 : null)}
        />
        Send code at 6 digits
      </label>
      <label {...stylex.props(styles.check)}>
        <input type="checkbox" checked={providersEnabled} onChange={(event) => lab.providersEnabled.set(event.currentTarget.checked)} />
        Enable Google and Apple
      </label>
      <fieldset {...stylex.props(styles.group)}>
        <legend {...stylex.props(styles.legend)}>Provider return</legend>
        <button type="button" onClick={() => void lab.returnFromProvider("ticket")}>
          With ticket
        </button>
        <button type="button" onClick={() => void lab.returnFromProvider("cancelled")}>
          Cancelled
        </button>
        <button type="button" onClick={() => void lab.returnFromProvider("mismatch")}>
          Other tab
        </button>
      </fieldset>
      <Segmented<LabTheme>
        label="Appearance"
        value={theme}
        options={["system", "light", "dark"]}
        onChange={(value) => {
          applyTheme(value)
          lab.theme.set(value)
        }}
      />
      <Segmented<LabDir>
        label="Direction"
        value={dir}
        options={["ltr", "rtl"]}
        onChange={(value) => {
          applyDir(value)
          lab.dir.set(value)
        }}
      />
      <Segmented<LabWidth> label="Width" value={width} options={["auto", "320"]} onChange={(value) => lab.width.set(value)} />
      <button type="button" onClick={() => lab.reset()}>
        Reset
      </button>
    </header>
  )
}

/** The model's state as text. Reads every signal through `useSignal`. */
function StatePanel(props: { model: ReturnType<SignInLab["createModel"]> }) {
  const model = props.model
  const state = {
    step: useSignal(model.step),
    method: useSignal(model.method),
    pending: useSignal(model.pending),
    error: useSignal(model.error),
    contact: useSignal(model.contact),
    existingUser: useSignal(model.existingUser),
    inviteCode: useSignal(model.inviteCode),
    resendSeconds: useSignal(model.resendSeconds),
    canResend: useSignal(model.canResend),
    canGoBack: useSignal(model.canGoBack),
    signedInUserId: useSignal(model.signedInUserId),
    user: useSignal(model.user),
  }
  const server = {
    next: useSignal(lab.server.next),
    newAccount: useSignal(lab.server.newAccount),
    lastNavigation: useSignal(lab.lastNavigation),
    requests: useSignal(lab.server.requests).map((request) => `${request.route} → ${request.answer}`),
  }
  return (
    <section aria-labelledby="lab-state-title" {...stylex.props(styles.panel)}>
      <h2 id="lab-state-title" {...stylex.props(styles.panelTitle)}>
        Model state
      </h2>
      <pre data-testid="signin-lab-state" {...stylex.props(styles.pre)}>
        {JSON.stringify(state, null, 2)}
      </pre>
      <h2 {...stylex.props(styles.panelTitle)}>Server</h2>
      <pre data-testid="signin-lab-server" {...stylex.props(styles.pre)}>
        {JSON.stringify(server, null, 2)}
      </pre>
    </section>
  )
}

/** The lab's own switcher: plain radio buttons, so it does not depend on the screen it tests. */
function Segmented<T extends string>(props: {
  label: string
  value: T
  options: readonly T[]
  labels?: Partial<Record<T, string>>
  onChange: (value: T) => void
}) {
  return (
    <fieldset {...stylex.props(styles.group)}>
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
          {props.labels?.[option] ?? option}
        </label>
      ))}
    </fieldset>
  )
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    display: "flex",
    flexDirection: "column",
    overflow: "auto",
    backgroundColor: color.sidebarBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  strip: {
    position: "sticky",
    top: 0,
    zIndex: 1,
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
  group: {
    display: "inline-flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.md,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.md, color: color.secondaryLabel },
  check: { display: "inline-flex", alignItems: "center", gap: space.xxs },
  main: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "flex-start",
    gap: space.xl,
    padding: space.xl,
  },
  stage: {
    display: "grid",
    flexGrow: 1,
    flexBasis: "420px",
    minBlockSize: "640px",
    overflow: "hidden",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
  },
  stageNarrow: { flexGrow: 0, flexBasis: "320px", inlineSize: "320px" },
  panel: {
    flexGrow: 1,
    flexBasis: "280px",
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
  },
  panelTitle: { margin: 0, fontSize: font.sizeHeadline, fontWeight: font.weightSemibold },
  pre: {
    margin: 0,
    padding: space.md,
    overflow: "auto",
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
})

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root")

createRoot(root).render(
  <StrictMode>
    <Lab />
  </StrictMode>,
)
