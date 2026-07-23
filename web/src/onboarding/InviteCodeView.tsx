import { useState, type FormEvent } from "react"
import * as stylex from "@stylexjs/stylex"
import { inlineAuthApi } from "~/inline/auth/auth-api"
import { FormError, OnboardingForm } from "./OnboardingFrame"
import { OnboardingButton } from "./OnboardingButton"
import { OnboardingField } from "./OnboardingField"

export function InviteCodeView({ onValid }: { onValid: (code: string) => void }) {
  const [code, setCode] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>()
  const normalized = code.trim().toUpperCase()

  const submit = async (event?: FormEvent) => {
    event?.preventDefault()
    if (normalized.length !== 8 || loading) return
    setLoading(true)
    setError(undefined)
    try {
      await inlineAuthApi.checkInviteCode(normalized)
      onValid(normalized)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The invite code is not valid.")
    } finally {
      setLoading(false)
    }
  }

  return (
    <OnboardingForm
      icon="ticket"
      title="Enter invite code"
      description="You need an invite to sign up for the alpha. You can get one from a user of Inline alpha or by joining the waitlist."
    >
      <form onSubmit={submit} {...stylex.props(styles.form)}>
        <OnboardingField
          autoFocus
          autoCapitalize="characters"
          autoComplete="one-time-code"
          placeholder="A7K2PQ9X"
          value={code}
          maxLength={8}
          disabled={loading}
          onChange={(event) =>
            setCode(event.currentTarget.value.toUpperCase().replaceAll(/[^A-Z0-9]/g, "").slice(0, 8))
          }
        />
        <FormError message={error} />
        <OnboardingButton type="submit" disabled={normalized.length !== 8 || loading}>
          {loading ? "Checking…" : "Continue"}
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
