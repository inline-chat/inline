import { useState, type FormEvent } from "react"
import * as stylex from "@stylexjs/stylex"
import { inlineAuthApi, type SendEmailCodeResult } from "~/inline/auth/auth-api"
import { FormError, OnboardingForm } from "./OnboardingFrame"
import { OnboardingButton } from "./OnboardingButton"
import { OnboardingField } from "./OnboardingField"

export function EmailView({
  initialEmail,
  onSent,
}: {
  initialEmail: string
  onSent: (email: string, result: SendEmailCodeResult) => void
}) {
  const [email, setEmail] = useState(initialEmail)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>()

  const submit = async (event?: FormEvent) => {
    event?.preventDefault()
    const normalized = email.trim().toLowerCase()
    if (!normalized || loading) return
    setLoading(true)
    setError(undefined)
    try {
      onSent(normalized, await inlineAuthApi.sendEmailCode(normalized))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not send a confirmation code.")
    } finally {
      setLoading(false)
    }
  }

  return (
    <OnboardingForm icon="at" title="Sign in with email">
      <form onSubmit={submit} {...stylex.props(styles.form)}>
        <OnboardingField
          autoFocus
          autoComplete="email"
          inputMode="email"
          name="email"
          placeholder="Your Email"
          value={email}
          disabled={loading}
          onChange={(event) => setEmail(event.currentTarget.value)}
        />
        <FormError message={error} />
        <OnboardingButton type="submit" disabled={!email.trim() || loading}>
          {loading ? "Sending…" : "Continue"}
        </OnboardingButton>
      </form>
    </OnboardingForm>
  )
}

const styles = stylex.create({
  form: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: 10,
    marginTop: 12,
  },
})
