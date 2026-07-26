import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import {
  makeWaitlistOperations,
  type WaitlistSubscription,
} from "./waitlist.effect"

const input: WaitlistSubscription = {
  email: "person@example.com",
}

const duplicateEmailError = Object.assign(
  new Error("duplicate key value violates unique constraint"),
  {
    code: "23505",
    constraint: "waitlist_email_unique",
  },
)

describe("waitlist operations", () => {
  it("treats an existing email subscription as a successful no-op", async () => {
    let notifyCalls = 0
    const operations = makeWaitlistOperations({
      count: async () => 0,
      insert: async () => {
        throw duplicateEmailError
      },
      notify: async () => {
        notifyCalls += 1
      },
      noteNotificationFailure: () => {},
    })

    await Effect.runPromise(operations.subscribe(input, undefined))

    expect(notifyCalls).toBe(0)
  })

  it("preserves unexpected insert failures", async () => {
    const cause = new Error("database unavailable")
    const operations = makeWaitlistOperations({
      count: async () => 0,
      insert: async () => {
        throw cause
      },
      notify: async () => {},
      noteNotificationFailure: () => {},
    })

    const failure = await Effect.runPromise(
      Effect.flip(operations.subscribe(input, undefined)),
    )

    expect(failure).toMatchObject({
      _tag: "WaitlistOperationFailure",
      operation: "subscribe",
      cause,
    })
  })
})
