import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import { InlineError } from "@in/server/types/errors"
import {
  makeIdentityOperations,
  type LegacyIdentityOperations,
} from "../modules/auth/identityOperationsAdapter.effect"
import {
  makeOAuthHttpService,
  type OAuthHttpHandlers,
} from "../modules/oauth/httpServiceAdapter.effect"
import {
  makeSessionAuthentication,
  SessionAuthenticationFailure,
  SessionAuthenticationRejected,
} from "./plugins.effect"

const unused = (operation: string): never => {
  throw new Error(`Unexpected adapter operation: ${operation}`)
}

const makeLegacyIdentity = (
  overrides: Partial<LegacyIdentityOperations> = {},
): LegacyIdentityOperations => ({
  sendSmsCode: async () => unused("sendSmsCode"),
  verifySmsCode: async () => unused("verifySmsCode"),
  sendEmailCode: async () => unused("sendEmailCode"),
  verifyEmailCode: async () => unused("verifyEmailCode"),
  checkInviteCode: async () => unused("checkInviteCode"),
  logout: async () => unused("logout"),
  ...overrides,
})

const makeOAuthHandlers = (
  overrides: Partial<OAuthHttpHandlers> = {},
): OAuthHttpHandlers => ({
  metadata: () => unused("metadata"),
  register: async () => unused("register"),
  authorize: async () => unused("authorize"),
  sendEmailCode: async () => unused("sendEmailCode"),
  verifyEmailCode: async () => unused("verifyEmailCode"),
  consent: async () => unused("consent"),
  token: async () => unused("token"),
  revoke: async () => unused("revoke"),
  introspect: async () => unused("introspect"),
  ...overrides,
})

describe("slice 2 live adapters", () => {
  it("maps session rejections separately from unexpected lookup failures", async () => {
    const rejectedCause = new Error("expired")
    const expected = new SessionAuthenticationRejected({
      error: "SESSION_REVOKED",
      errorCode: 401,
      description: "revoked",
      connectionReason:
        ConnectionError_Reason.SESSION_REVOKED,
    })
    const rejected = makeSessionAuthentication({
      authenticateToken: async () => {
        throw rejectedCause
      },
      classifyRejection: (cause) =>
        cause === rejectedCause ? expected : undefined,
    })

    const rejection = await Effect.runPromise(
      Effect.flip(rejected.authenticate("42:token")),
    )
    expect(rejection).toBe(expected)

    const unexpected = makeSessionAuthentication({
      authenticateToken: async () => {
        throw new Error("database unavailable")
      },
      classifyRejection: () => undefined,
    })
    expect(
      (
        await Effect.runPromise(
          Effect.flip(
            unexpected.authenticate("42:token"),
          ),
        )
      )._tag,
    ).toBe("SessionAuthenticationFailure")
  })

  it("validates branded session identity at the legacy trust boundary", async () => {
    const adapter = makeSessionAuthentication({
      authenticateToken: async () => ({
        userId: 0,
        sessionId: 7,
      }),
      classifyRejection: () => undefined,
    })

    const error = await Effect.runPromise(
      Effect.flip(adapter.authenticate("0:token")),
    )

    expect(error).toBeInstanceOf(
      SessionAuthenticationFailure,
    )
  })

  it("invokes identity legacy operations and validates their response shape", async () => {
    let received: unknown
    const adapter = makeIdentityOperations(
      makeLegacyIdentity({
        sendSmsCode: async (input, context) => {
          received = { input, context }
          return {
            existingUser: false,
            needsInviteCode: true,
            phoneNumber: "+12025550123",
            formattedPhoneNumber: "+1 202 555 0123",
          }
        },
      }),
    )

    const result = await Effect.runPromise(
      adapter.sendSmsCode(
        { phoneNumber: "+12025550123" },
        {
          ip: "203.0.113.10",
          source: "/v1/sendSmsCode",
        },
      ),
    )

    expect(result.needsInviteCode).toBe(true)
    expect(received).toEqual({
      input: { phoneNumber: "+12025550123" },
      context: {
        ip: "203.0.113.10",
        source: "/v1/sendSmsCode",
      },
    })
  })

  it("keeps expected Inline errors typed at the identity boundary", async () => {
    const adapter = makeIdentityOperations(
      makeLegacyIdentity({
        sendEmailCode: async () => {
          throw new InlineError(
            InlineError.ApiError.EMAIL_INVALID,
          )
        },
      }),
    )

    const error = await Effect.runPromise(
      Effect.flip(
        adapter.sendEmailCode(
          { email: "invalid" },
          {
            ip: undefined,
            source: "/v1/sendEmailCode",
          },
        ),
      ),
    )

    expect(error).toMatchObject({
      _tag: "IdentityPublicError",
      error: "EMAIL_INVALID",
      errorCode: 400,
    })
  })

  it("retains and reports the private cause of identity 500 errors", async () => {
    const privateCause = new Error("database unavailable")
    const adapter = makeIdentityOperations(
      makeLegacyIdentity({
        sendEmailCode: async () => {
          throw new InlineError(
            InlineError.ApiError.INTERNAL,
            { cause: privateCause },
          )
        },
      }),
    )

    const error = await Effect.runPromise(
      Effect.flip(
        adapter.sendEmailCode(
          { email: "person@example.com" },
          {
            ip: "203.0.113.10",
            source: "/v1/sendEmailCode",
          },
        ),
      ),
    )

    expect(error).toMatchObject({
      _tag: "IdentityOperationFailure",
      cause: privateCause,
      publicError: {
        _tag: "IdentityPublicError",
        error: "INTERNAL",
        errorCode: 500,
      },
    })
  })

  it("parses repeated OAuth form fields before invoking the canonical handler", async () => {
    let received: unknown
    const adapter = makeOAuthHttpService(
      makeOAuthHandlers({
        consent: async (_request, body) => {
          received = body
          return new Response("ok")
        },
      }),
    )
    const response = await Effect.runPromise(
      adapter.execute("consent", {
        request: new Request(
          "http://inline.test/oauth/authorize/consent",
          {
            method: "POST",
            headers: {
              "content-type":
                "application/x-www-form-urlencoded",
            },
            body: "space_id=1&space_id=2&allow_dms=1",
          },
        ),
      }),
    )

    expect(await response.text()).toBe("ok")
    expect(received).toEqual({
      space_id: ["1", "2"],
      allow_dms: "1",
    })
  })

  it("preserves Elysia's malformed OAuth JSON boundary", async () => {
    let calls = 0
    const adapter = makeOAuthHttpService(
      makeOAuthHandlers({
        register: async () => {
          calls += 1
          return new Response()
        },
      }),
    )
    const response = await Effect.runPromise(
      adapter.execute("register", {
        request: new Request(
          "http://inline.test/oauth/register",
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{",
          },
        ),
      }),
    )

    expect(response.status).toBe(400)
    expect(response.headers.has("content-type")).toBe(false)
    expect(await response.text()).toBe("Bad Request")
    expect(calls).toBe(0)
  })
})
