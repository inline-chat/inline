import { useState, type FormEvent } from "react"
import * as stylex from "@stylexjs/stylex"
import { inlineAuthApi, type SendSmsCodeResult } from "~/inline/auth/auth-api"
import { FormError, OnboardingForm } from "./OnboardingFrame"
import { OnboardingButton } from "./OnboardingButton"
import { OnboardingField } from "./OnboardingField"
import {
  isPlausibleInternationalPhoneNumber,
  normalizeInternationalPhoneNumber,
} from "./phone-number"

export function PhoneView({
  initialPhoneNumber,
  onSent,
}: {
  initialPhoneNumber: string
  onSent: (result: SendSmsCodeResult) => void
}) {
  const [phoneNumber, setPhoneNumber] = useState(initialPhoneNumber)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>()
  const normalized = normalizeInternationalPhoneNumber(phoneNumber)

  const submit = async (event?: FormEvent) => {
    event?.preventDefault()
    if (loading) return
    if (!isPlausibleInternationalPhoneNumber(normalized)) {
      setError("Enter your phone number with its country code, such as +1 415 555 2671.")
      return
    }

    setLoading(true)
    setError(undefined)
    try {
      onSent(await inlineAuthApi.sendSmsCode(normalized))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not send a confirmation code.")
    } finally {
      setLoading(false)
    }
  }

  return (
    <OnboardingForm
      icon="phone"
      title="Continue with phone"
      description="Include your country code. Standard message rates may apply."
    >
      <form onSubmit={submit} {...stylex.props(styles.form)}>
        <OnboardingField
          autoFocus
          autoComplete="tel"
          inputMode="tel"
          name="phoneNumber"
          placeholder="+1 415 555 2671"
          value={phoneNumber}
          disabled={loading}
          onChange={(event) => setPhoneNumber(event.currentTarget.value)}
        />
        <FormError message={error} />
        <OnboardingButton type="submit" disabled={!normalized || loading}>
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
