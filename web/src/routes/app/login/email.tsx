import { createFileRoute, useNavigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import type { FormEvent } from "react"
import { useState } from "react"
import { LargeButton } from "~/components/form/LargeButton"
import { LargeTextField } from "~/components/form/LargeTextField"
import { ApiClient, ApiError } from "~/modules/api"

export const Route = createFileRoute("/app/login/email")({
  component: RouteComponent,
})

function RouteComponent() {
  const navigate = useNavigate()
  const [email, setEmail] = useState("")
  const [isLoading, setIsLoading] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const isValidEmail = (value: string) => /\S+@\S+\.\S+/.test(value.trim())
  const canSubmit = email.trim().length > 0

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

  const sendEmailCode = async () => {
    const trimmedEmail = email.trim()
    if (!trimmedEmail) {
      setErrorMessage("Enter your email address.")
      return
    }
    if (!isValidEmail(trimmedEmail)) {
      setErrorMessage("Enter a valid email address.")
      return
    }

    setIsLoading(true)
    setErrorMessage(null)
    try {
      const result = await ApiClient.sendEmailCode(trimmedEmail)
      await navigate({
        to: "/app/login/code",
        search: {
          method: "email",
          email: trimmedEmail,
          challengeToken: result.challengeToken,
        },
      })
    } catch (error) {
      setErrorMessage(formatError(error))
    } finally {
      setIsLoading(false)
    }
  }

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault()
    if (isLoading) return
    void sendEmailCode()
  }

  return (
    <>
      <div {...stylex.props(styles.subheading)}>Continue via Email</div>

      <form onSubmit={handleSubmit} {...stylex.props(styles.form)}>
        <LargeTextField
          placeholder="Enter your email"
          type="email"
          autoComplete="email"
          value={email}
          onChange={(event) => {
            setEmail(event.target.value)
            setErrorMessage(null)
          }}
        />
        <div {...stylex.props(styles.helperText)}>
          We'll email you a short verification code.
        </div>

        {errorMessage ? <div {...stylex.props(styles.errorText)}>{errorMessage}</div> : null}

        <LargeButton type="submit" disabled={!canSubmit || isLoading}>
          {isLoading ? "Working..." : "Continue"}
        </LargeButton>
      </form>
    </>
  )
}

const styles = stylex.create({
  topBar: {
    appRegion: "drag",
    height: 42,
    width: "100%",
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    zIndex: 100,
  },

  content: {
    height: "100%",

    display: "flex",

    flexDirection: "column",
    justifyContent: "center",
    alignItems: "center",
  },

  logo: {
    margin: "0 auto",
    textAlign: "center",
    width: 120,
    filter: "invert(1)",
  },

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

  errorText: {
    fontSize: 14,
    color: "crimson",
    textAlign: "center",
  },
})
