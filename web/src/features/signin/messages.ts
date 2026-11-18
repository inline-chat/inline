/**
 * The words the sign-in screen shows, kept out of the views so they can be
 * tested and later translated. English only for now.
 *
 * Error text never includes the server's description or any value the user
 * typed: only the error kind and, for a rate limit, the wait.
 */

import type { PendingAction, ProviderName, SignInError, SignInMethod } from "@inline/auth/flows"
import { formatWait } from "./format"

export const providerLabel = (provider: ProviderName): string =>
  provider === "google" ? "Google" : "Apple"

/** The sentence shown for an error, in the step where it happened. */
export const errorMessage = (error: SignInError, method: SignInMethod | null): string => {
  switch (error.kind) {
    case "network":
      return "Can't reach Inline. Check your connection and try again."
    case "rateLimited":
      return error.retryAfterSeconds != null && error.retryAfterSeconds > 0
        ? `Too many attempts. Try again in ${formatWait(error.retryAfterSeconds)}.`
        : "Too many attempts. Wait a minute and try again."
    case "invalidCode":
      return "That code isn't right. Check it and try again."
    case "expiredCode":
      return "That code has expired. Send a new one."
    case "inviteRequired":
      return "An access invite code is needed to create an account."
    case "invalidInvite":
      switch (error.reason) {
        case "format":
          return "Invite codes are 8 letters and numbers."
        case "notFound":
          return "That invite code wasn't found. Check it and try again."
        case "taken":
          return "That invite code has already been used."
      }
      return "That invite code didn't work."
    case "invalidEmail":
      return "Enter a valid email address."
    case "invalidPhone":
      return "Enter a valid phone number, starting with the country code."
    case "signupsDisabled":
      return "New accounts can't be created right now."
    case "accountDeactivated":
      return "This account has been deactivated."
    case "invalidTicket":
      return "This sign-in has expired. Start again."
    case "providerCancelled":
      return "Sign-in was cancelled."
    case "providerFailed":
      return method === "google" || method === "apple"
        ? `Sign-in with ${providerLabel(method)} didn't finish. Try again.`
        : "Sign-in didn't finish. Try again."
    case "providerStateMismatch":
      return "This sign-in was started somewhere else or has expired. Start again from this tab."
    case "server":
      return "Something went wrong on our side. Try again in a moment."
  }
}

/**
 * Whether the error is about what is in the step's field, so the field is
 * marked invalid and described by the message. Network, server and rate
 * limit errors are not the field's fault.
 */
export const isFieldError = (error: SignInError): boolean => {
  switch (error.kind) {
    case "invalidCode":
    case "expiredCode":
    case "invalidInvite":
    case "invalidEmail":
    case "invalidPhone":
      return true
    default:
      return false
  }
}

/** Whether the code field should be emptied after this error (the code is spent or wrong). */
export const clearsCode = (error: SignInError): boolean =>
  error.kind === "invalidCode" || error.kind === "expiredCode"

/** The accessible label of the progress indicator while an action runs. */
export const pendingLabel = (pending: PendingAction): string => {
  switch (pending) {
    case "sendCode":
      return "Sending code"
    case "resendCode":
      return "Sending a new code"
    case "verifyCode":
      return "Checking code"
    case "checkInvite":
      return "Checking invite code"
    case "providerStart":
      return "Starting sign-in"
    case "providerRedeem":
      return "Finishing sign-in"
    case "signOut":
      return "Signing out"
  }
}

/** The code step's submit label, as on the Mac: sign in, create an account, or neutral. */
export const codeSubmitLabel = (existingUser: boolean | null): string =>
  existingUser === true ? "Sign in" : existingUser === false ? "Create account" : "Continue"

/** The resend control's label for the current countdown. */
export const resendLabel = (seconds: number, sending: boolean, formatted: string): string => {
  if (sending) return "Sending a new code…"
  return seconds > 0 ? `Send a new code in ${formatted}` : "Send a new code"
}

/** A name to greet a signed-in user with, falling back to how they signed in. */
export const displayName = (
  user: { firstName: string | null; lastName: string | null; username: string | null } | null,
  contact: string | null,
): string | null => {
  const full = [user?.firstName, user?.lastName].filter((part) => part && part.trim()).join(" ").trim()
  if (full) return full
  if (user?.username) return `@${user.username}`
  return contact
}
