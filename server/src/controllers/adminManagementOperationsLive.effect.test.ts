import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Effect,
  Schema,
} from "effect"
import {
  SessionId,
  UserId,
} from "../core/schema/identifiers"
import type {
  AdminSessionValue,
} from "./adminSecurity.effect"
import {
  AdminOperationFailure,
} from "./adminOperations.effect"
import {
  makeTestEmailProviderOperation,
} from "./adminEmailProviderTestOperation.effect"

const adminSession: AdminSessionValue = {
  sessionId: Schema.decodeUnknownSync(SessionId)(7),
  userId: Schema.decodeUnknownSync(UserId)(42),
  email: "operator@inline.chat",
  firstName: "Inline",
  lastName: "Operator",
  passwordSet: true,
  totpEnabled: true,
  stepUpAt: new Date(),
}

describe("Admin email provider test operation", () => {
  it.effect("sends only to the authenticated Admin without changing configuration", () =>
    Effect.gen(function* () {
      const deliveries: unknown[] = []
      const testEmailProvider = makeTestEmailProviderOperation(
        async (input) => {
          deliveries.push(input)
          return { messageId: "provider-message-id" }
        },
      )

      const result = yield* testEmailProvider(
        { provider: "ses" },
        adminSession,
      )

      expect(deliveries).toEqual([{
        provider: "ses",
        to: "operator@inline.chat",
        content: {
          subject: "[TEST] Inline Amazon SES delivery",
          text: expect.stringContaining("active email provider setting was not changed"),
          html: expect.stringContaining("active email provider setting was not changed"),
        },
      }])
      expect(result).toMatchObject({
        kind: "json",
        body: {
          ok: true,
          provider: "ses",
          recipient: "operator@inline.chat",
          fromAddress: "team@inline.chat",
          replyToAddress: "hi@inline.chat",
          messageId: "provider-message-id",
          sentAt: expect.any(String),
        },
      })
    }),
  )

  it.effect("keeps provider failures private and typed", () =>
    Effect.gen(function* () {
      const providerCause = new Error("provider-private-cause")
      const testEmailProvider = makeTestEmailProviderOperation(
        async () => {
          throw providerCause
        },
      )

      const failure = yield* Effect.flip(
        testEmailProvider(
          { provider: "resend" },
          adminSession,
        ),
      )

      expect(failure).toEqual(
        new AdminOperationFailure({
          operation: "admin.email-provider-test.deliver",
          cause: providerCause,
        }),
      )
    }),
  )
})
