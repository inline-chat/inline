import { createFileRoute, useNavigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import type { FormEvent } from "react"
import { useMemo, useState } from "react"
import { LargeButton } from "~/components/form/LargeButton"
import { LargeTextField } from "~/components/form/LargeTextField"
import { ApiClient, ApiError } from "~/modules/api"
import { useAuthActions } from "@inline/client"

type LoginMethod = "email" | "phone"

export const Route = createFileRoute("/app/login/code")({
  component: RouteComponent,
})

function RouteComponent() {
  const navigate = useNavigate()
  const { login } = useAuthActions()
  const [code, setCode] = useState("")
  const [isLoading, setIsLoading] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const search = Route.useSearch() as {
    method?: string
    email?: string
    phone?: string
    phoneNumber?: string
  }

  const details = useMemo(() => {
    const method: LoginMethod | null =
      search.method === "phone" || search.method === "sms"
        ? "phone"
        : search.method === "email"
          ? "email"
          : null

    const email = method === "email" ? search.email?.trim() : undefined
    const phoneNumber =
      method === "phone" ? (search.phoneNumber ?? search.phone)?.trim() : undefined

    return {
      method,
      email,
      phoneNumber,
      contact: email ?? phoneNumber ?? "",
      isMissing: !method || !(email ?? phoneNumber),
    }
  }, [search.email, search.method, search.phone, search.phoneNumber])

  const canSubmit = code.trim().length > 0 && !details.isMissing

  const formatError = (error: unknown) => {
    if (error instanceof ApiError) {
      if (error.kind === "rate-limited") {
        return "Too many attempts. Please try again in a bit."
      }
      return error.description ?? error.apiError ?? error.message
    }
    if (error instanceof Error) return error.message
    return "Something went wrong. Please try again."
  }

  const verifyCode = async () => {
    if (details.isMissing || !details.method) {
      setErrorMessage("Missing login details. Please start again.")
      return
    }

    const trimmedCode = code.trim()
    if (!trimmedCode) {
      setErrorMessage("Enter the verification code.")
      return
    }

    setIsLoading(true)
    setErrorMessage(null)
    try {
      const result =
        details.method === "email" && details.email
          ? await ApiClient.verifyEmailCode(trimmedCode, details.email)
          : details.phoneNumber
            ? await ApiClient.verifySmsCode(trimmedCode, details.phoneNumber)
            : null

      if (!result) {
        setErrorMessage("Missing login details. Please start again.")
        return
      }

      login({ token: result.token, userId: result.userId })
      ApiClient.setToken(result.token)
      await navigate({ to: "/app" })
    } catch (error) {
      setErrorMessage(formatError(error))
    } finally {
      setIsLoading(false)
    }
  }

  const resendCode = async () => {
    if (details.isMissing || !details.method) {
      setErrorMessage("Missing login details. Please start again.")
      return
    }

    setIsLoading(true)
    setErrorMessage(null)
    try {
      if (details.method === "email" && details.email) {
        await ApiClient.sendEmailCode(details.email)
      } else if (details.phoneNumber) {
        await ApiClient.sendSmsCode(details.phoneNumber)
      } else {
        setErrorMessage("Missing login details. Please start again.")
      }
    } catch (error) {
      setErrorMessage(formatError(error))
    } finally {
      setIsLoading(false)
    }
  }

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault()
    if (isLoading) return
    void verifyCode()
  }

  const handleResend = () => {
    if (isLoading) return
    void resendCode()
  }

  const handleChange = () => {
    if (isLoading) return
    const next = details.method === "email" ? "/app/login/email" : "/app/login/welcome"
    void navigate({ to: next })
  }

  return (
    <>
      <div {...stylex.props(styles.subheading)}>Enter your verification code</div>

      <form onSubmit={handleSubmit} {...stylex.props(styles.form)}>
        {details.isMissing ? (
          <div {...stylex.props(styles.helperText)}>
            Missing login details. Please return to start again.
          </div>
        ) : (
          <div {...stylex.props(styles.helperText)}>
            We sent a code to <span {...stylex.props(styles.contactText)}>{details.contact}</span>
          </div>
        )}

        <LargeTextField
          placeholder="Enter the code"
          type="text"
          inputMode="numeric"
          autoComplete="one-time-code"
          value={code}
          onChange={(event) => {
            setCode(event.target.value)
            setErrorMessage(null)
          }}
          disabled={details.isMissing}
        />

        {errorMessage ? <div {...stylex.props(styles.errorText)}>{errorMessage}</div> : null}

        <LargeButton type="submit" disabled={!canSubmit || isLoading}>
          {isLoading ? "Working..." : "Verify"}
        </LargeButton>

        <div {...stylex.props(styles.secondaryActions)}>
          <button
            type="button"
            onClick={handleResend}
            disabled={details.isMissing || isLoading}
            {...stylex.props(styles.textButton)}
          >
            Resend code
          </button>
          <button type="button" onClick={handleChange} {...stylex.props(styles.textButton)}>
            {details.method === "email" ? "Change email" : "Use a different method"}
          </button>
        </div>
      </form>
    </>
  )
}

const styles = stylex.create({
  subheading: {
    fontSize: 24,
    maxWidth: 500,
    margin: "0 auto",
    opacity: 0.8,
    textAlign: "center",
    fontWeight: 500,
    marginTop: 38,
    marginBottom: 38,
  },

  form: {
    width: "100%",
    maxWidth: 420,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: 14,
  },

  helperText: {
    fontSize: 14,
    color: "gray",
    textAlign: "center",
  },

  contactText: {
    fontWeight: 600,
  },

  errorText: {
    fontSize: 14,
    color: "crimson",
    textAlign: "center",
  },

  secondaryActions: {
    display: "flex",
    gap: 16,
  },

  textButton: {
    border: "none",
    background: "transparent",
    color: "blue",
    fontSize: 14,
    cursor: "pointer",
    padding: 0,
    opacity: 0.9,
    ":disabled": {
      opacity: 0.5,
      cursor: "not-allowed",
    },
  },
})
