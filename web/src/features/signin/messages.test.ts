import type { SignInError } from "@inline/auth/flows"
import { describe, expect, test } from "vitest"
import {
  clearsCode,
  codeSubmitLabel,
  displayName,
  errorMessage,
  isFieldError,
  pendingLabel,
  resendLabel,
} from "./messages"

const everyError: SignInError[] = [
  { kind: "network" },
  { kind: "rateLimited", retryAfterSeconds: 30 },
  { kind: "rateLimited", retryAfterSeconds: null },
  { kind: "invalidCode" },
  { kind: "expiredCode" },
  { kind: "inviteRequired" },
  { kind: "invalidInvite", reason: "format" },
  { kind: "invalidInvite", reason: "notFound" },
  { kind: "invalidInvite", reason: "taken" },
  { kind: "invalidEmail" },
  { kind: "invalidPhone" },
  { kind: "signupsDisabled" },
  { kind: "accountDeactivated" },
  { kind: "invalidTicket" },
  { kind: "providerCancelled" },
  { kind: "providerFailed" },
  { kind: "providerStateMismatch" },
  { kind: "server", status: 500, code: "SERVER_ERROR" },
]

describe("errorMessage", () => {
  test("every error has a sentence, and none leaks a server code or status", () => {
    for (const error of everyError) {
      const text = errorMessage(error, "email")
      expect(text.length).toBeGreaterThan(10)
      expect(text.endsWith(".")).toBe(true)
      expect(text).not.toMatch(/SERVER_ERROR|500|undefined|null/)
    }
  })

  test("a rate limit says how long to wait when the server said", () => {
    expect(errorMessage({ kind: "rateLimited", retryAfterSeconds: 30 }, "email")).toBe(
      "Too many attempts. Try again in 30 seconds.",
    )
    expect(errorMessage({ kind: "rateLimited", retryAfterSeconds: 90 }, "phone")).toBe(
      "Too many attempts. Try again in 2 minutes.",
    )
    expect(errorMessage({ kind: "rateLimited", retryAfterSeconds: null }, "phone")).toBe(
      "Too many attempts. Wait a minute and try again.",
    )
  })

  test("wrong and expired codes read differently", () => {
    expect(errorMessage({ kind: "invalidCode" }, "email")).not.toBe(
      errorMessage({ kind: "expiredCode" }, "email"),
    )
  })

  test("a provider failure names the provider", () => {
    expect(errorMessage({ kind: "providerFailed" }, "google")).toContain("Google")
    expect(errorMessage({ kind: "providerFailed" }, "apple")).toContain("Apple")
    expect(errorMessage({ kind: "providerFailed" }, null)).toBe("Sign-in didn't finish. Try again.")
  })
})

describe("isFieldError and clearsCode", () => {
  test("field errors are about what was typed", () => {
    expect(isFieldError({ kind: "invalidEmail" })).toBe(true)
    expect(isFieldError({ kind: "invalidPhone" })).toBe(true)
    expect(isFieldError({ kind: "invalidCode" })).toBe(true)
    expect(isFieldError({ kind: "expiredCode" })).toBe(true)
    expect(isFieldError({ kind: "invalidInvite", reason: "notFound" })).toBe(true)
    expect(isFieldError({ kind: "network" })).toBe(false)
    expect(isFieldError({ kind: "rateLimited", retryAfterSeconds: 5 })).toBe(false)
    expect(isFieldError({ kind: "server", status: 500, code: null })).toBe(false)
  })

  test("only a wrong or expired code empties the code field", () => {
    expect(clearsCode({ kind: "invalidCode" })).toBe(true)
    expect(clearsCode({ kind: "expiredCode" })).toBe(true)
    expect(clearsCode({ kind: "network" })).toBe(false)
    expect(clearsCode({ kind: "rateLimited", retryAfterSeconds: null })).toBe(false)
  })
})

describe("labels", () => {
  test("code submit follows existingUser, as on the Mac", () => {
    expect(codeSubmitLabel(true)).toBe("Sign in")
    expect(codeSubmitLabel(false)).toBe("Create account")
    expect(codeSubmitLabel(null)).toBe("Continue")
  })

  test("resend shows the countdown, then the action", () => {
    expect(resendLabel(42, false, "0:42")).toBe("Send a new code in 0:42")
    expect(resendLabel(0, false, "0:00")).toBe("Send a new code")
    expect(resendLabel(0, true, "0:00")).toBe("Sending a new code…")
  })

  test("every pending action has a label", () => {
    for (const action of [
      "sendCode",
      "resendCode",
      "verifyCode",
      "checkInvite",
      "providerStart",
      "providerRedeem",
      "signOut",
    ] as const) {
      expect(pendingLabel(action).length).toBeGreaterThan(3)
    }
  })

  test("display name prefers the name, then the username, then the contact", () => {
    expect(displayName({ firstName: "Ada", lastName: "Lovelace", username: "ada" }, "a@b.c")).toBe(
      "Ada Lovelace",
    )
    expect(displayName({ firstName: "Ada", lastName: null, username: null }, null)).toBe("Ada")
    expect(displayName({ firstName: " ", lastName: null, username: "ada" }, null)).toBe("@ada")
    expect(displayName({ firstName: null, lastName: null, username: null }, "a@b.c")).toBe("a@b.c")
    expect(displayName(null, null)).toBe(null)
  })
})
