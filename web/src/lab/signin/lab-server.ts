/**
 * A scripted stand-in for the sign-in routes, for the sign-in lab only. It
 * answers `fetch` by route with the answer chosen in the lab's control strip;
 * nothing leaves the page. The answer applies to the next request and then
 * falls back to "success".
 *
 * Requests are recorded by route and answer only: no codes, contacts or
 * tokens are kept, so the lab state can be printed and read safely.
 */

import type { Clock, FetchLike } from "@inline/auth/flows"
import { EMAIL_CODE_LIFETIME_MS } from "@inline/auth/flows"
import { signal } from "@inline/reactive"

export const LAB_API_BASE = "https://lab.invalid/v1"

export const LAB_ANSWERS = [
  "success",
  "wrongCode",
  "expiredCode",
  "rateLimited",
  "inviteRequired",
  "networkFailure",
  "slow",
] as const

export type LabAnswer = (typeof LAB_ANSWERS)[number]

export const LAB_ANSWER_LABELS: Record<LabAnswer, string> = {
  success: "Success",
  wrongCode: "Wrong code",
  expiredCode: "Expired code",
  rateLimited: "Rate limited",
  inviteRequired: "Invite required",
  networkFailure: "Network failure",
  slow: "Slow (3 s), then success",
}

export type LabRequest = { at: number; route: string; answer: LabAnswer }

const SLOW_MS = 3_000
const RETRY_AFTER_SECONDS = 30

type Reply = { status: number; body?: unknown; headers?: Record<string, string> } | "network"

const ok = (result?: unknown): Reply => ({ status: 200, body: result === undefined ? { ok: true } : { ok: true, result } })

const failure = (status: number, error: string, headers?: Record<string, string>): Reply => ({
  status,
  body: { ok: false, error, errorCode: status, description: "Lab description (never shown)" },
  ...(headers ? { headers } : {}),
})

/**
 * A clock that runs on real time plus an offset the lab can push forward.
 * "Expired code" moves it past the email code lifetime, which is how the
 * model tells an expired code from a wrong one.
 */
export class LabClock implements Clock {
  offsetMs = 0
  now = () => Date.now() + this.offsetMs
  setTimeout = (callback: () => void, ms: number) => globalThis.setTimeout(callback, ms)
  clearTimeout = (handle: unknown) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>)
}

export class LabServer {
  /** The answer for the next request. */
  readonly next = signal<LabAnswer>("success")
  /** When on, sends say "new user" and sign-ins come back with `pendingSetup`. */
  readonly newAccount = signal(false)
  readonly requests = signal<readonly LabRequest[]>([])

  constructor(private readonly clock: LabClock) {}

  fetch: FetchLike = async (url) => {
    if (!url.startsWith(LAB_API_BASE)) throw new TypeError("Failed to fetch")
    const route = url.slice(LAB_API_BASE.length)
    const answer = this.next.peek()
    this.next.set("success")
    this.requests.set([...this.requests.peek(), { at: Date.now(), route, answer }].slice(-20))

    if (answer === "slow") await new Promise((resolve) => globalThis.setTimeout(resolve, SLOW_MS))
    const reply = this.reply(route, answer)
    if (reply === "network") throw new TypeError("Failed to fetch")
    return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), {
      status: reply.status,
      headers: { "content-type": "application/json", ...reply.headers },
    })
  }

  private reply(route: string, answer: LabAnswer): Reply {
    if (answer === "networkFailure") return "network"
    if (answer === "rateLimited") return failure(420, "FLOOD", { "retry-after": String(RETRY_AFTER_SECONDS) })
    const existingUser = !this.newAccount.peek()

    switch (route) {
      case "/sendEmailCode":
        if (answer === "wrongCode" || answer === "expiredCode") return failure(400, "EMAIL_INVALID")
        return ok({ existingUser, needsInviteCode: answer === "inviteRequired", challengeToken: "lab-challenge" })

      case "/sendSmsCode":
        if (answer === "wrongCode" || answer === "expiredCode") return failure(400, "PHONE_INVALID")
        return ok({
          existingUser,
          needsInviteCode: answer === "inviteRequired",
          phoneNumber: "+14155550100",
          formattedPhoneNumber: "+1 415 555 0100",
        })

      case "/verifyEmailCode":
      case "/verifySmsCode": {
        const invalid = route === "/verifyEmailCode" ? "EMAIL_CODE_INVALID" : "SMS_CODE_INVALID"
        if (answer === "wrongCode") return failure(400, invalid)
        if (answer === "expiredCode") {
          // The server answers the same for wrong and expired; the model
          // infers "expired" from the code's age, so age it.
          this.clock.offsetMs += EMAIL_CODE_LIFETIME_MS + 1_000
          return failure(400, invalid)
        }
        if (answer === "inviteRequired") return failure(400, "INVITE_CODE_REQUIRED")
        return ok(this.session())
      }

      case "/checkInviteCode":
        if (answer === "wrongCode" || answer === "expiredCode") return ok({ valid: false })
        return ok({ valid: true })

      case "/auth/provider/redeem":
        if (answer === "wrongCode" || answer === "expiredCode") return { status: 401, body: { error: "invalid_ticket" } }
        return ok(this.session())

      case "/logout":
        return ok()

      default:
        return failure(404, "NOT_FOUND")
    }
  }

  private session() {
    const pendingSetup = this.newAccount.peek()
    return {
      userId: 42,
      token: "lab-session-token",
      user: {
        id: 42,
        firstName: pendingSetup ? null : "Ada",
        lastName: pendingSetup ? null : "Lovelace",
        username: pendingSetup ? null : "ada",
        email: "ada@example.com",
        phoneNumber: null,
        pendingSetup,
        timeZone: "Europe/London",
        date: 1_700_000_000,
      },
    }
  }
}
