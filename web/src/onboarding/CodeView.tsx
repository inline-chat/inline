import { useEffect, useRef, useState, type FormEvent } from "react"
import * as stylex from "@stylexjs/stylex"
import { authSession } from "~/inline/auth/auth-session"
import { inlineAuthApi, type VerifyCodeResult } from "~/inline/auth/auth-api"
import { FormError, OnboardingForm } from "./OnboardingFrame"
import { OnboardingButton } from "./OnboardingButton"
import { OnboardingField } from "./OnboardingField"

export function CodeView({
  identity,
  inviteCode,
  existingUser,
  onVerified,
}: {
  identity:
    | { kind: "email"; email: string; challengeToken?: string }
    | { kind: "phone"; phoneNumber: string; formattedPhoneNumber: string }
  inviteCode?: string
  existingUser?: boolean
  onVerified: (result: VerifyCodeResult) => void
}) {
  const [code, setCode] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>()
  const submittedCode = useRef<string | undefined>(undefined)

  const submit = async (event?: FormEvent) => {
    event?.preventDefault()
    if (code.length !== 6 || loading || submittedCode.current === code) return
    submittedCode.current = code
    setLoading(true)
    setError(undefined)
    try {
      const result =
        identity.kind === "email"
          ? await inlineAuthApi.verifyEmailCode({
              email: identity.email,
              code,
              challengeToken: identity.challengeToken,
              inviteCode,
            })
          : await inlineAuthApi.verifySmsCode({
              phoneNumber: identity.phoneNumber,
              code,
              inviteCode,
            })
      await authSession.login({
        token: result.token,
        userId: result.userId,
      })
      onVerified(result)
    } catch (cause) {
      submittedCode.current = undefined
      setError(cause instanceof Error ? cause.message : "The confirmation code is not valid.")
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (code.length === 6) void submit()
  }, [code])

  const label = existingUser == null ? "Continue" : existingUser ? "Log In" : "Sign Up"

  return (
    <OnboardingForm
      icon="numbers"
      title="Enter confirmation code"
      description={
        identity.kind === "phone"
          ? `We sent a code to ${identity.formattedPhoneNumber}.`
          : `We sent a code to ${identity.email}.`
      }
    >
      <form onSubmit={submit} {...stylex.props(styles.form)}>
        <OnboardingField
          autoFocus
          autoComplete="one-time-code"
          inputMode="numeric"
          placeholder="123654"
          value={code}
          maxLength={6}
          disabled={loading}
          onChange={(event) => setCode(event.currentTarget.value.replaceAll(/\D/g, "").slice(0, 6))}
        />
        <FormError message={error} />
        <OnboardingButton type="submit" disabled={code.length !== 6 || loading}>
          {loading ? "Checking…" : label}
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
