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
  OpenApi,
} from "effect/unstable/httpapi"
import {
  makePlatformApiBase,
} from "../core/http/openApi"
import {
  AdminApiGroup,
} from "./admin.effect"
import {
  verifyAdminEmailChallenge,
} from "./adminEmailChallenge.effect"
import {
  makeAdminLoginIpRateLimiter,
} from "./adminLoginRateLimit.effect"
import {
  AdminOperationFailure,
  AdminRejected,
} from "./adminOperations.effect"
import {
  AdminUserMembership,
  AdminUserSession,
} from "./adminSchemas.effect"

const spec = () =>
  OpenApi.fromApi(
    makePlatformApiBase(
      "https://api.inline.chat",
    ).add(AdminApiGroup),
  )

const responseHeader = (
  response: unknown,
  name: string,
): unknown => {
  if (
    typeof response !== "object" ||
    response === null ||
    !("headers" in response) ||
    typeof response.headers !== "object" ||
    response.headers === null
  ) {
    return undefined
  }
  return name in response.headers
    ? response.headers[name as keyof typeof response.headers]
    : undefined
}

describe("Admin Effect contracts", () => {
  it("describes route-specific errors, binary avatars, and session cookies", () => {
    const document = spec()
    const login =
      document.paths["/admin/auth/login"]?.post
    const me = document.paths["/admin/me"]?.get
    const avatar =
      document.paths["/admin/users/{id}/avatar"]
        ?.get

    expect(
      Object.keys(login?.responses ?? {}).sort(),
    ).toEqual(
      [
        "200",
        "400",
        "401",
        "403",
        "420",
        "422",
        "429",
        "500",
      ],
    )
    expect(
      responseHeader(
        login?.responses["200"],
        "Set-Cookie",
      ),
    ).toMatchObject({
      description: expect.stringContaining("HttpOnly"),
    })
    expect(
      responseHeader(
        document.paths[
          "/admin/auth/verify-email-code"
        ]?.post?.responses["200"],
        "Set-Cookie",
      ),
    ).toBeDefined()
    expect(
      responseHeader(
        document.paths["/admin/auth/logout"]?.post
          ?.responses["200"],
        "Set-Cookie",
      ),
    ).toMatchObject({
      description:
        expect.stringContaining("Max-Age=0"),
    })

    expect(me?.responses["400"]).toBeUndefined()
    expect(me?.responses["404"]).toBeUndefined()
    expect(me?.responses["422"]).toBeUndefined()
    expect(me?.responses["503"]).toBeUndefined()

    expect(
      avatar?.responses["200"]?.content?.["image/*"]
        ?.schema,
    ).toMatchObject({
      type: "string",
      format: "binary",
    })
    for (const status of [
      400,
      401,
      403,
      404,
      503,
    ] as const) {
      expect(
        avatar?.responses[status]?.content,
      ).toBeUndefined()
    }
    expect(avatar?.parameters[0]).toMatchObject({
      name: "id",
      in: "path",
      required: true,
      schema: {
        type: "string",
        description:
          "A positive safe-integer user identifier.",
      },
    })

    expect(
      document.components.schemas?.[
        "AdminLoginForbidden"
      ],
    ).toMatchObject({
      properties: {
        error: {
          enum: [
            "not_allowed",
            "password_not_set",
          ],
        },
      },
    })
    expect(
      document.components.schemas?.[
        "_inline_server_admin_AdminUnauthorizedError"
      ],
    ).toMatchObject({
      properties: {
        error: {
          enum: ["unauthorized"],
        },
      },
    })
  })

  it("accepts nullable membership roles and session client types from live rows", () => {
    const membership = Schema.decodeUnknownSync(
      AdminUserMembership,
    )({
      id: 1,
      role: null,
      canAccessPublicChats: false,
      invitedBy: null,
      joinedAt: null,
      space: {
        id: 2,
        name: "Internal",
        handle: null,
        isPublic: false,
        createdAt: null,
        deletedAt: null,
      },
    })
    const userSession = Schema.decodeUnknownSync(
      AdminUserSession,
    )({
      id: 3,
      clientType: null,
      clientVersion: null,
      osVersion: null,
      lastActive: null,
      active: true,
      deviceId: null,
      date: null,
      revoked: null,
      personalData: {},
    })

    expect(membership.role).toBeNull()
    expect(userSession.clientType).toBeNull()
  })

  it("keeps the process-local login window bounded and deterministic", () => {
    let now = 1_000
    const limiter = makeAdminLoginIpRateLimiter({
      maxAttempts: 2,
      windowMs: 100,
      maxKeys: 2,
      now: () => now,
    })

    expect(limiter.tryRecord("192.0.2.1")).toBe(true)
    expect(limiter.tryRecord("192.0.2.1")).toBe(true)
    expect(limiter.tryRecord("192.0.2.1")).toBe(false)

    now = 1_101
    expect(limiter.tryRecord("192.0.2.1")).toBe(true)
    expect(limiter.tryRecord("192.0.2.2")).toBe(true)
    expect(limiter.tryRecord("192.0.2.3")).toBe(true)
    expect(limiter.size()).toBe(2)

    limiter.clear("192.0.2.3")
    expect(limiter.size()).toBe(1)
  })

  it("distinguishes a wrong email code from verifier infrastructure failure", async () => {
    const input = {
      email: "admin@inline.chat",
      code: "123456",
      challengeToken: "challenge",
    }

    const wrongCode = await Effect.runPromise(
      verifyAdminEmailChallenge(
        input,
        () => Promise.resolve(false),
      ).pipe(Effect.flip),
    )
    expect(wrongCode).toBeInstanceOf(AdminRejected)
    expect(wrongCode).toMatchObject({
      status: 401,
      error: "invalid_code",
    })

    const cause = new Error("verifier unavailable")
    const unavailable = await Effect.runPromise(
      verifyAdminEmailChallenge(
        input,
        () => Promise.reject(cause),
      ).pipe(Effect.flip),
    )
    expect(unavailable).toBeInstanceOf(
      AdminOperationFailure,
    )
    expect(unavailable).toMatchObject({
      operation:
        "admin.auth.verify-email-code.verify",
      cause,
    })
  })
})
