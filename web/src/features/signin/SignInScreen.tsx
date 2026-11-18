/**
 * The sign-in screen: renders a `SignInModel` from `@inline/auth/flows`.
 *
 * Every step shares one frame (mark, title, body, fields, one message region,
 * actions) and a back control above it. All flow logic, pending state, errors
 * and the resend countdown come from the model through `useSignal`; this file
 * only renders them and forwards input. See README.md.
 */

import {
  INVITE_CODE_LENGTH,
  type PendingAction,
  type ProviderName,
  type SignInError,
  type SignInMethod,
  type SignInModel,
  type SignInStep,
} from "@inline/auth/flows"
import { useSignal } from "@inline/reactive/react"
import { Button, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { type FormEvent, type MouseEvent, type ReactNode, useId, useState } from "react"
import { Field } from "./Field"
import { focusFieldAfterError, focusOnMount } from "./focus"
import { formatCountdown, isCodeComplete, normalizeCodeInput, normalizeInviteInput, prefillContact } from "./format"
import { BackIcon, ErrorIcon, InlineMark, SuccessIcon } from "./icons"
import {
  clearsCode,
  codeSubmitLabel,
  displayName,
  errorMessage,
  isFieldError,
  pendingLabel,
  providerLabel,
  resendLabel,
} from "./messages"

export type SignInScreenProps = {
  model: SignInModel
  /**
   * Providers whose buttons are active. Default none: the server's provider
   * route does not accept a web client yet, so Google and Apple render
   * disabled with a short reason.
   */
  enabledProviders?: readonly ProviderName[]
  /** Sends the tab to the provider's start URL. Defaults to `location.assign`. */
  navigate?: (url: string) => void
  /**
   * The expected code length, when known. With it, the code is sent as soon
   * as that many digits are typed or pasted. The model does not expose one yet.
   */
  codeLength?: number
}

type Message = { tone: "error" | "success"; text: string }

type StepProps = {
  model: SignInModel
  /** The ID of the step's message region, for `aria-describedby`. */
  messageId: string
}

const PROVIDERS: readonly ProviderName[] = ["google", "apple"]
const TERMS_URL = "https://inline.chat/legal/terms"
const PRIVACY_URL = "https://inline.chat/legal/privacy"

const assignLocation = (url: string) => {
  window.location.assign(url)
}

/** The sign-in screen. Fills its container; give it the full window. */
export function SignInScreen(props: SignInScreenProps) {
  const step = useSignal(props.model.step)
  const messageId = useId()
  const stepProps: StepProps = { model: props.model, messageId }
  return (
    <div {...stylex.props(styles.screen)}>
      <div {...stylex.props(styles.column)}>
        <BackBar model={props.model} step={step} />
        <div {...stylex.props(styles.mark)}>
          <InlineMark size={40} />
        </div>
        {step === "welcome" && (
          <WelcomeStep
            {...stepProps}
            enabledProviders={props.enabledProviders ?? []}
            navigate={props.navigate ?? assignLocation}
          />
        )}
        {step === "email" && <EmailStep {...stepProps} />}
        {step === "phone" && <PhoneStep {...stepProps} />}
        {step === "invite" && <InviteStep {...stepProps} />}
        {step === "code" && <CodeStep {...stepProps} codeLength={props.codeLength} />}
        {step === "provider" && (
          <ProviderStep
            {...stepProps}
            enabledProviders={props.enabledProviders ?? []}
            navigate={props.navigate ?? assignLocation}
          />
        )}
        {step === "setup" && <SetupStep {...stepProps} />}
        {step === "done" && <DoneStep {...stepProps} />}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Shared frame

/**
 * The back control. Its row is always there, so steps do not move when it
 * appears. After sign-in the model's back signs out, so it says so.
 */
function BackBar(props: { model: SignInModel; step: SignInStep }) {
  const canGoBack = useSignal(props.model.canGoBack)
  const pending = useSignal(props.model.pending)
  const visible = canGoBack && props.step !== "done"
  const signsOut = props.step === "setup"
  return (
    <div {...stylex.props(styles.backBar)}>
      {visible && (
        <Button
          variant="plain"
          size="small"
          icon={signsOut ? undefined : <BackIcon />}
          disabled={pending === "signOut"}
          onClick={() => void props.model.back()}
        >
          {signsOut ? (pending === "signOut" ? "Signing out…" : "Sign out") : "Back"}
        </Button>
      )}
    </div>
  )
}

function StepFrame(props: {
  title: string
  body?: ReactNode
  /** Focus the title when the step mounts (steps without a field). */
  focusTitle?: boolean
  icon?: ReactNode
  messageId: string
  message: Message | null
  busy?: boolean
  /** With a handler the fields and actions are a form, so Enter submits. */
  onSubmit?: (event: FormEvent<HTMLFormElement>) => void
  children?: ReactNode
  actions?: ReactNode
  footer?: ReactNode
}) {
  const titleId = useId()
  const content = (
    <>
      {props.children}
      <MessageRegion id={props.messageId} message={props.message} />
      {props.actions && <div {...stylex.props(styles.actions)}>{props.actions}</div>}
    </>
  )
  return (
    <section aria-labelledby={titleId} {...stylex.props(styles.step)}>
      <header {...stylex.props(styles.header)}>
        {props.icon}
        <h1
          id={titleId}
          tabIndex={props.focusTitle ? -1 : undefined}
          ref={props.focusTitle ? focusOnMount : undefined}
          {...stylex.props(styles.title)}
        >
          {props.title}
        </h1>
        {props.body && <p {...stylex.props(styles.body)}>{props.body}</p>}
      </header>
      {props.onSubmit ? (
        <form
          noValidate
          aria-labelledby={titleId}
          aria-busy={props.busy || undefined}
          onSubmit={props.onSubmit}
          {...stylex.props(styles.content)}
        >
          {content}
        </form>
      ) : (
        <div aria-busy={props.busy || undefined} {...stylex.props(styles.content)}>
          {content}
        </div>
      )}
      {props.footer}
    </section>
  )
}

/**
 * The one place a step's error or notice appears. Always rendered, so screen
 * readers announce what is put into it (politely), and it reserves a line so
 * an error does not push the actions down.
 */
function MessageRegion(props: { id: string; message: Message | null }) {
  const message = props.message
  return (
    <p
      id={props.id}
      role="status"
      aria-live="polite"
      aria-atomic="true"
      {...stylex.props(styles.message, message?.tone === "error" ? styles.messageError : styles.messageSuccess)}
    >
      {message && (
        <>
          <span {...stylex.props(styles.messageIcon, message.tone === "error" ? styles.iconError : styles.iconSuccess)}>
            {message.tone === "error" ? <ErrorIcon /> : <SuccessIcon />}
          </span>
          <span>{message.text}</span>
        </>
      )}
    </p>
  )
}

/**
 * The step's submit button. While a request runs it is disabled and shows a
 * spinner over its label, which keeps its width, so nothing moves.
 */
function SubmitButton(props: { label: string; pending: PendingAction | null; busyFor: readonly PendingAction[] }) {
  const busy = props.pending !== null && props.busyFor.includes(props.pending)
  return (
    <Button
      type="submit"
      variant="primary"
      size="large"
      disabled={props.pending !== null}
      style={[styles.wide, styles.submit, busy && styles.busyButton]}
    >
      <span {...stylex.props(busy && styles.hiddenLabel)}>{props.label}</span>
      {busy && props.pending !== null && (
        <span {...stylex.props(styles.spinnerSlot)}>
          <Progress variant="spinner" label={pendingLabel(props.pending)} />
        </span>
      )}
    </Button>
  )
}

/**
 * A contact or name inside a sentence, isolated so the surrounding text's
 * direction does not reorder it. Emails and phone numbers are left to right;
 * a name picks its own direction.
 */
function Contact(props: { value: string; dir?: "ltr" | "auto" }) {
  return (
    <bdi dir={props.dir ?? "auto"} {...stylex.props(styles.contact)}>
      {props.value}
    </bdi>
  )
}

const errorOf = (error: SignInError | null, method: SignInMethod | null): Message | null =>
  error ? { tone: "error", text: errorMessage(error, method) } : null

// ---------------------------------------------------------------------------
// Steps

function WelcomeStep(props: StepProps & { enabledProviders: readonly ProviderName[]; navigate: (url: string) => void }) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const reasonId = useId()
  const anyDisabled = PROVIDERS.some((provider) => !props.enabledProviders.includes(provider))
  const start = async (provider: ProviderName) => {
    const url = await props.model.startProvider(provider)
    if (url) props.navigate(url)
  }
  return (
    <StepFrame
      title="Welcome to Inline"
      body="Sign in or create an account to continue."
      focusTitle
      messageId={props.messageId}
      message={errorOf(error, method)}
      busy={pending !== null}
      actions={
        <>
          <Button
            variant="primary"
            size="large"
            style={styles.wide}
            disabled={pending !== null}
            onClick={() => props.model.chooseEmail()}
          >
            Continue with email
          </Button>
          <Button
            variant="secondary"
            size="large"
            style={styles.wide}
            disabled={pending !== null}
            onClick={() => props.model.choosePhone()}
          >
            Continue with phone
          </Button>
          <div role="separator" {...stylex.props(styles.divider)} />
          {PROVIDERS.map((provider) => {
            const enabled = props.enabledProviders.includes(provider)
            return (
              <Button
                key={provider}
                variant="secondary"
                size="large"
                style={styles.wide}
                disabled={!enabled || pending !== null}
                aria-describedby={enabled ? undefined : reasonId}
                onClick={() => void start(provider)}
              >
                Continue with {providerLabel(provider)}
              </Button>
            )
          })}
          {anyDisabled && (
            <p id={reasonId} {...stylex.props(styles.note)}>
              Google and Apple sign-in aren't available on the web yet.
            </p>
          )}
        </>
      }
      footer={
        <p {...stylex.props(styles.footer)}>
          By continuing, you agree to the{" "}
          <a href={TERMS_URL} target="_blank" rel="noopener noreferrer" {...stylex.props(styles.link)}>
            Terms of Service
          </a>{" "}
          and{" "}
          <a href={PRIVACY_URL} target="_blank" rel="noopener noreferrer" {...stylex.props(styles.link)}>
            Privacy Policy
          </a>
          .
        </p>
      }
    />
  )
}

function EmailStep(props: StepProps) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const contact = useSignal(props.model.contact)
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const form = event.currentTarget
    const value = fieldValue(form, "email")
    await props.model.submitEmail(value)
    if (props.model.error.peek() && props.model.step.peek() === "email") focusFieldAfterError(form, { select: true })
  }
  return (
    <StepFrame
      title="Continue with email"
      body="We'll send a code to confirm it's you."
      messageId={props.messageId}
      message={errorOf(error, method)}
      busy={pending !== null}
      onSubmit={(event) => void submit(event)}
      actions={<SubmitButton label="Continue" pending={pending} busyFor={["sendCode"]} />}
    >
      <Field
        ref={focusOnMount}
        label="Email"
        name="email"
        type="email"
        inputMode="email"
        autoComplete="email"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        enterKeyHint="go"
        defaultValue={prefillContact("email", contact)}
        readOnly={pending !== null}
        invalid={error !== null && isFieldError(error)}
        messageId={props.messageId}
        onInput={() => {
          if (error) props.model.clearError()
        }}
      />
    </StepFrame>
  )
}

function PhoneStep(props: StepProps) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const contact = useSignal(props.model.contact)
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const form = event.currentTarget
    await props.model.submitPhone(fieldValue(form, "phone"))
    if (props.model.error.peek() && props.model.step.peek() === "phone") focusFieldAfterError(form, { select: true })
  }
  return (
    <StepFrame
      title="Continue with phone"
      body="We'll text you a code to confirm it's you."
      messageId={props.messageId}
      message={errorOf(error, method)}
      busy={pending !== null}
      onSubmit={(event) => void submit(event)}
      actions={<SubmitButton label="Continue" pending={pending} busyFor={["sendCode"]} />}
    >
      <Field
        ref={focusOnMount}
        label="Phone number"
        hint="Start with the country code, for example +1 for the US."
        name="phone"
        type="tel"
        inputMode="tel"
        autoComplete="tel"
        dir="ltr"
        enterKeyHint="go"
        defaultValue={prefillContact("phone", contact)}
        readOnly={pending !== null}
        invalid={error !== null && isFieldError(error)}
        messageId={props.messageId}
        onInput={() => {
          if (error) props.model.clearError()
        }}
      />
    </StepFrame>
  )
}

function InviteStep(props: StepProps) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const accepted = useSignal(props.model.inviteCode)
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const form = event.currentTarget
    await props.model.submitInvite(fieldValue(form, "invite"))
    if (props.model.error.peek() && props.model.step.peek() === "invite") focusFieldAfterError(form, { select: true })
  }
  const sentTo = method === "phone" ? "phone" : "email"
  return (
    <StepFrame
      title="Enter your access invite code"
      body={`Inline needs an invite code to create an account. It's separate from the verification code sent to your ${sentTo}.`}
      messageId={props.messageId}
      message={errorOf(error, method)}
      busy={pending !== null}
      onSubmit={(event) => void submit(event)}
      actions={<SubmitButton label="Continue" pending={pending} busyFor={["checkInvite", "verifyCode"]} />}
    >
      <Field
        ref={focusOnMount}
        label="Access invite code"
        hint={`${INVITE_CODE_LENGTH} letters and numbers`}
        name="invite"
        autoComplete="off"
        autoCapitalize="characters"
        autoCorrect="off"
        spellCheck={false}
        dir="ltr"
        enterKeyHint="go"
        defaultValue={accepted ?? ""}
        readOnly={pending !== null}
        invalid={error !== null && isFieldError(error)}
        messageId={props.messageId}
        onInput={(event) => {
          const input = event.currentTarget
          const next = normalizeInviteInput(input.value, INVITE_CODE_LENGTH)
          if (next !== input.value) input.value = next
          if (error) props.model.clearError()
        }}
      />
    </StepFrame>
  )
}

function CodeStep(props: StepProps & { codeLength: number | undefined }) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const contact = useSignal(props.model.contact)
  const existingUser = useSignal(props.model.existingUser)
  const resendSeconds = useSignal(props.model.resendSeconds)
  const canResend = useSignal(props.model.canResend)
  // View-local: "a new code was sent" after a resend that succeeded.
  const [resent, setResent] = useState(false)

  const verify = async (form: HTMLFormElement, code: string) => {
    setResent(false)
    await props.model.submitCode(code)
    const failed = props.model.error.peek()
    if (!failed || props.model.step.peek() !== "code") return
    // A wrong or expired code is not shown back to the user.
    const input = form.elements.namedItem("code")
    if (clearsCode(failed) && input instanceof HTMLInputElement) input.value = ""
    focusFieldAfterError(form, { select: true })
  }

  const resend = async (event: MouseEvent<HTMLButtonElement>) => {
    const form = event.currentTarget.form
    setResent(false)
    await props.model.resendCode()
    if (props.model.step.peek() !== "code") return
    if (!props.model.error.peek()) {
      setResent(true)
      const input = form?.elements.namedItem("code")
      if (input instanceof HTMLInputElement) input.value = ""
    }
    focusFieldAfterError(form ?? null)
  }

  const message: Message | null = error
    ? errorOf(error, method)
    : resent
      ? { tone: "success", text: contact ? `We sent a new code to ${contact}.` : "We sent a new code." }
      : null

  return (
    <StepFrame
      title={method === "phone" ? "Check your messages" : "Check your email"}
      body={
        contact ? (
          <>
            Enter the code we sent to <Contact value={contact} dir="ltr" />.
          </>
        ) : (
          "Enter the code we sent you."
        )
      }
      messageId={props.messageId}
      message={message}
      busy={pending !== null}
      onSubmit={(event) => {
        event.preventDefault()
        const form = event.currentTarget
        void verify(form, fieldValue(form, "code"))
      }}
      actions={
        <>
          <SubmitButton label={codeSubmitLabel(existingUser)} pending={pending} busyFor={["verifyCode"]} />
          <Button
            variant="plain"
            style={[styles.wide, styles.tabular]}
            disabled={!canResend}
            onClick={(event) => void resend(event)}
          >
            {resendLabel(resendSeconds, pending === "resendCode", formatCountdown(resendSeconds))}
          </Button>
        </>
      }
    >
      <Field
        ref={focusOnMount}
        label="Code"
        name="code"
        variant="code"
        inputMode="numeric"
        autoComplete="one-time-code"
        autoCorrect="off"
        spellCheck={false}
        dir="ltr"
        enterKeyHint="done"
        defaultValue=""
        readOnly={pending !== null}
        invalid={error !== null && isFieldError(error)}
        messageId={props.messageId}
        onInput={(event) => {
          const input = event.currentTarget
          const next = normalizeCodeInput(input.value, props.codeLength)
          if (next !== input.value) input.value = next
          if (error) props.model.clearError()
          if (resent) setResent(false)
          if (isCodeComplete(next, props.codeLength) && pending === null && input.form) {
            void verify(input.form, next)
          }
        }}
      />
    </StepFrame>
  )
}

function ProviderStep(props: StepProps & { enabledProviders: readonly ProviderName[]; navigate: (url: string) => void }) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const provider = method === "google" || method === "apple" ? method : null
  const name = provider ? providerLabel(provider) : null
  const canRetry = provider !== null && props.enabledProviders.includes(provider)
  const retry = async () => {
    if (!provider) return
    const url = await props.model.startProvider(provider)
    if (url) props.navigate(url)
  }

  if (error) {
    return (
      <StepFrame
        title="Sign-in didn't finish"
        body={name ? `Nothing was changed. You can try ${name} again or go back.` : "Nothing was changed. Go back to try again."}
        focusTitle
        messageId={props.messageId}
        message={{ tone: "error", text: errorMessage(error, method) }}
        actions={
          canRetry && (
            <Button variant="primary" size="large" style={styles.wide} onClick={() => void retry()}>
              Try {name} again
            </Button>
          )
        }
      />
    )
  }

  return (
    <StepFrame
      title={pending === "providerRedeem" ? "Finishing sign-in" : name ? `Continue with ${name}` : "Continue in your browser"}
      body={
        <span {...stylex.props(styles.inlineProgress)}>
          <Progress variant="spinner" label={pending ? pendingLabel(pending) : "Waiting for sign-in"} />
          {pending === "providerRedeem"
            ? "Checking your account…"
            : name
              ? `Opening ${name} sign-in…`
              : "Waiting for sign-in…"}
        </span>
      }
      focusTitle
      busy
      messageId={props.messageId}
      message={null}
    />
  )
}

function SetupStep(props: StepProps) {
  const pending = useSignal(props.model.pending)
  const error = useSignal(props.model.error)
  const method = useSignal(props.model.method)
  const user = useSignal(props.model.user)
  const contact = useSignal(props.model.contact)
  const name = displayName(user, contact)
  return (
    <StepFrame
      title="Your account is ready"
      body={
        name ? (
          <>
            You're signed in as <Contact value={name} />.
          </>
        ) : (
          "You're signed in."
        )
      }
      messageId={props.messageId}
      message={errorOf(error, method)}
      busy={pending !== null}
      actions={
        <Button
          ref={focusOnMount}
          variant="primary"
          size="large"
          style={styles.wide}
          disabled={pending !== null}
          onClick={() => props.model.finishSetup()}
        >
          Continue
        </Button>
      }
    />
  )
}

function DoneStep(props: StepProps) {
  const user = useSignal(props.model.user)
  const contact = useSignal(props.model.contact)
  const name = displayName(user, contact)
  return (
    <StepFrame
      icon={
        <span {...stylex.props(styles.doneIcon)}>
          <SuccessIcon size={28} />
        </span>
      }
      title="You're signed in"
      body={
        name ? (
          <>
            Welcome, <Contact value={name} />.
          </>
        ) : (
          "Welcome to Inline."
        )
      }
      focusTitle
      messageId={props.messageId}
      message={null}
    />
  )
}

/** Reads a named field's current text from the form (the fields are uncontrolled). */
const fieldValue = (form: HTMLFormElement, name: string): string => {
  const field = form.elements.namedItem(name)
  return field instanceof HTMLInputElement ? field.value : ""
}

// ---------------------------------------------------------------------------
// Styles

const styles = stylex.create({
  screen: {
    boxSizing: "border-box",
    minBlockSize: "100%",
    display: "grid",
    placeItems: "center",
    paddingBlock: space.huge,
    paddingInline: space.xl,
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  column: {
    display: "flex",
    flexDirection: "column",
    gap: space.lg,
    inlineSize: "100%",
    maxInlineSize: "360px",
    minWidth: 0,
  },
  backBar: {
    display: "flex",
    alignItems: "center",
    justifyContent: "flex-start",
    // The control's height is reserved even when it is hidden.
    minBlockSize: size.controlSmall,
    marginInlineStart: `calc(-1 * ${space.md})`,
  },
  mark: { display: "flex", justifyContent: "center", color: color.label },
  step: { display: "flex", flexDirection: "column", gap: space.xxl, minWidth: 0 },
  header: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: space.sm,
    textAlign: "center",
  },
  title: {
    margin: 0,
    fontSize: font.sizeTitle1,
    fontWeight: font.weightSemibold,
    lineHeight: font.lineHeightTight,
    outline: "none",
    overflowWrap: "anywhere",
  },
  body: {
    margin: 0,
    fontSize: font.sizeTitle3,
    color: color.secondaryLabel,
    overflowWrap: "anywhere",
  },
  content: { display: "flex", flexDirection: "column", gap: space.lg, minWidth: 0 },
  actions: { display: "flex", flexDirection: "column", gap: space.md },
  wide: { inlineSize: "100%" },
  tabular: { fontVariantNumeric: "tabular-nums" },
  submit: { position: "relative" },
  busyButton: { opacity: 1 },
  hiddenLabel: { visibility: "hidden" },
  spinnerSlot: {
    position: "absolute",
    inset: 0,
    display: "grid",
    placeItems: "center",
  },
  message: {
    display: "flex",
    alignItems: "flex-start",
    gap: space.sm,
    margin: 0,
    // One line is always reserved, so a one-line error moves nothing.
    minBlockSize: "1lh",
    fontSize: font.sizeBody,
    overflowWrap: "anywhere",
  },
  messageError: { color: color.red },
  messageSuccess: { color: color.label },
  messageIcon: { display: "flex", paddingBlockStart: "1px" },
  iconError: { color: color.red },
  iconSuccess: { color: color.green },
  divider: {
    blockSize: "1px",
    marginBlock: space.xs,
    backgroundColor: color.separator,
  },
  note: {
    margin: 0,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    textAlign: "center",
  },
  footer: {
    margin: 0,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    textAlign: "center",
  },
  link: {
    color: color.link,
    textDecoration: { default: "none", ":hover": "underline" },
  },
  contact: { color: color.label, fontWeight: font.weightMedium },
  inlineProgress: { display: "inline-flex", alignItems: "center", gap: space.sm },
  doneIcon: { display: "flex", color: color.green },
})
