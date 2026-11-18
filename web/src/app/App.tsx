/**
 * The gate: one switch on the app model's phase.
 *
 * - `booting`: a neutral frame in the window color while the auth store is
 *   read (local and fast), so a signed-in user never sees sign-in flash.
 * - `signedOut`: the sign-in screen over the model, full window, with a
 *   notice when the account ended elsewhere (another tab, revocation).
 * - `signedIn`: the shell, keyed by the session.
 * - `signingOut`: a neutral frame that says so (silent when the session
 *   being torn down was only painted from the boot snapshot and the auth
 *   store did not confirm it).
 *
 * With a boot snapshot the first phase is `signedIn` (runtime.ts): the shell
 * renders in the first frame from the snapshot, marked
 * `inline.boot.snapshot-paint` once painted.
 *
 * The sign-in screen and the shell are separate chunks (`views.ts`), and the
 * sign-in model's flows are a chunk too (`signin-loader.ts`); until the ones
 * needed have loaded, the neutral frame stands in.
 *
 * A new account's setup step stays on screen after the account signed in
 * (`runtime.heldSignIn`): the session starts behind it, and the shell
 * replaces it when the user continues.
 */

import { useModel, useElement, useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { AccountSession } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import type { AppServices } from "./services"
import type { LazySignIn } from "./signin-loader"
import { eraseIncompleteText } from "./status"

export function App(props: { services: AppServices }) {
  const phase = useSignal(props.services.runtime.app.phase)
  const held = useSignal(props.services.runtime.heldSignIn)
  switch (phase.kind) {
    case "booting":
      return <NeutralFrame label="Opening Inline" />
    case "signingOut":
      return <SigningOutFrame services={props.services} />
    case "signedOut":
      return <SignInGate services={props.services} signIn={phase.signIn} />
    case "signedIn":
      if (held) return <SignInGate services={props.services} signIn={held} />
      return <ShellGate key={phase.session.userId} services={props.services} session={phase.session} />
  }
}

/** The window color and, when asked, one quiet line. The label is always there for assistive technology. */
export function NeutralFrame(props: { label: string; visible?: boolean }) {
  return (
    <div role="status" aria-live="polite" {...stylex.props(styles.frame)}>
      <span {...stylex.props(props.visible ? styles.frameText : styles.visuallyHidden)}>{props.label}</span>
    </div>
  )
}

/** "Signing out…", except when the account ending was only painted from the boot snapshot. */
function SigningOutFrame(props: { services: AppServices }) {
  const snapshot = useSignal(props.services.runtime.bootSnapshot)
  if (snapshot === "discarded") return <NeutralFrame label="Opening Inline" />
  return <NeutralFrame label="Signing out…" visible />
}

function LoadFailed(props: { services: AppServices; retry: () => void }) {
  return (
    <div role="alert" {...stylex.props(styles.frame, styles.column)}>
      <p {...stylex.props(styles.frameText)}>Inline couldn't load. Check your connection and try again.</p>
      <Button variant="primary" onClick={props.retry}>
        Try Again
      </Button>
    </div>
  )
}

function SignInGate(props: { services: AppServices; signIn: LazySignIn }) {
  const { services, signIn } = props
  const Screen = useSignal(services.views.signIn.value)
  const failed = useSignal(services.views.signIn.error)
  const model = useSignal(signIn.model)
  const modelFailed = useSignal(signIn.error)
  const reason = useSignal(services.runtime.signedOutReason)
  const eraseIncomplete = useSignal(services.runtime.eraseIncomplete)
  const marker = useModel(() => (_element: HTMLElement) => {
    services.runtime.metrics.markAfterPaint("signInPaint")
    services.warmup.painted()
  })
  const paintRef = useElement(marker)
  if (!Screen || !model) {
    if (failed || modelFailed) {
      const retry = () => {
        void services.views.signIn.load()
        signIn.retry()
      }
      return <LoadFailed services={services} retry={retry} />
    }
    return <NeutralFrame label="Opening Inline" />
  }
  return (
    <div ref={paintRef} {...stylex.props(styles.signIn)}>
      {(reason || eraseIncomplete) && (
        <div role="status" {...stylex.props(styles.notice)}>
          <span>
            {reason === "revoked"
              ? "This session was ended. Sign in again to continue."
              : reason === "elsewhere"
                ? "You were signed out in another tab or window."
                : null}
            {reason && eraseIncomplete ? " " : null}
            {eraseIncomplete ? `${eraseIncompleteText.title} ${eraseIncompleteText.body}` : null}
          </span>
          <Button variant="plain" size="small" onClick={() => services.runtime.dismissSignedOutReason()}>
            Dismiss
          </Button>
        </div>
      )}
      <div {...stylex.props(styles.signInScreen)}>
        <Screen model={model} codeLength={services.codeLength} />
      </div>
    </div>
  )
}

function ShellGate(props: { services: AppServices; session: AccountSession }) {
  const { services } = props
  const Shell = useSignal(services.views.shell.value)
  const failed = useSignal(services.views.shell.error)
  if (!Shell) {
    if (failed) return <LoadFailed services={services} retry={() => void services.views.shell.load()} />
    return <NeutralFrame label="Opening Inline" />
  }
  const shell = <Shell services={services} session={props.session} />
  return props.session.restoredFromSnapshot ? <SnapshotPaint services={services}>{shell}</SnapshotPaint> : shell
}

/** Marks the first paint of a shell restored from the boot snapshot. Adds no box (`display: contents`). */
function SnapshotPaint(props: { services: AppServices; children: ReactNode }) {
  const { metrics } = props.services.runtime
  const marker = useModel(() => (_element: HTMLElement) => {
    metrics.markAfterPaint("snapshotPaint")
    props.services.warmup.painted()
  })
  const paintRef = useElement(marker)
  return (
    <div ref={paintRef} {...stylex.props(styles.contents)}>
      {props.children}
    </div>
  )
}

const styles = stylex.create({
  frame: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.lg,
    blockSize: "100%",
    backgroundColor: color.windowBackground,
    color: color.secondaryLabel,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  column: {
    flexDirection: "column",
  },
  contents: {
    display: "contents",
  },
  frameText: {
    margin: 0,
  },
  visuallyHidden: {
    position: "absolute",
    inlineSize: 1,
    blockSize: 1,
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
  signIn: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    backgroundColor: color.windowBackground,
  },
  signInScreen: {
    flexGrow: 1,
    minBlockSize: 0,
    overflowY: "auto",
  },
  notice: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.md,
    paddingBlock: space.sm,
    paddingInline: space.xl,
    backgroundColor: color.controlHover,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
  },
})
