import { useState, type FormEvent } from "react"
import * as stylex from "@stylexjs/stylex"
import { authSession } from "~/inline/auth/auth-session"
import { inlineAuthApi } from "~/inline/auth/auth-api"
import { FormError, OnboardingForm } from "./OnboardingFrame"
import { OnboardingButton } from "./OnboardingButton"
import { OnboardingField } from "./OnboardingField"

export function ProfileView({ onComplete }: { onComplete: () => void }) {
  const [name, setName] = useState("")
  const [username, setUsername] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>()

  const submit = async (event?: FormEvent) => {
    event?.preventDefault()
    const token = authSession.getToken()
    const normalizedName = name.trim()
    if (!token || !normalizedName || loading) return

    const [firstName = normalizedName, ...rest] = normalizedName.split(/\s+/)
    setLoading(true)
    setError(undefined)
    try {
      await inlineAuthApi.updateProfile(
        {
          firstName,
          lastName: rest.join(" ") || undefined,
          username: username.trim().replace(/^@/, "") || undefined,
        },
        token,
      )
      onComplete()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update your profile.")
    } finally {
      setLoading(false)
    }
  }

  return (
    <OnboardingForm icon="person" title="Set up your profile">
      <form onSubmit={submit} {...stylex.props(styles.form)}>
        <OnboardingField
          autoFocus
          autoComplete="name"
          placeholder="Your Name"
          value={name}
          disabled={loading}
          onChange={(event) => setName(event.currentTarget.value)}
        />
        <OnboardingField
          autoComplete="username"
          placeholder="@username"
          value={username}
          disabled={loading}
          onChange={(event) => setUsername(event.currentTarget.value)}
        />
        <FormError message={error} />
        <OnboardingButton type="submit" disabled={!name.trim() || loading}>
          {loading ? "Saving…" : "Continue"}
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
    gap: 8,
    marginTop: 12,
  },
})
