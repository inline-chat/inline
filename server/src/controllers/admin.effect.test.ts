import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
  Schema,
} from "effect"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import {
  OpenApi,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
  type UnexpectedErrorReport,
} from "../core/errors/errorReporter"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "../core/http/application"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
} from "../core/http/openApi"
import {
  assertValidOpenApiDocument,
} from "../core/http/openApiValidation"
import {
  SessionId,
  UserId,
} from "../core/schema/identifiers"
import {
  AdminApiGroup,
  AdminRouteGroup,
} from "./admin.effect"
import {
  AdminOperationFailure,
  AdminOperations,
  AdminRejected,
  type AdminOperationsShape,
} from "./adminOperations.effect"
import {
  adminSessionCookie,
  clearedAdminSessionCookie,
} from "./adminCookies.effect"
import {
  AdminAvatarAuthenticationLive,
  AdminAvatarOriginGuardLive,
  AdminAvatarSetupCompleteLive,
  AdminAuthenticationLive,
  AdminOriginGuardLive,
  AdminRecentStepUpLive,
  AdminSessionLookupFailure,
  AdminSessionStore,
  AdminSetupCompleteLive,
  type AdminSessionValue,
} from "./adminSecurity.effect"

interface Probe {
  readonly calls: string[]
  readonly sessionTokens: Array<
    string | undefined
  >
  session: AdminSessionValue | null
}

const session = (
  overrides: Partial<AdminSessionValue> = {},
): AdminSessionValue => ({
  sessionId: Schema.decodeUnknownSync(SessionId)(7),
  userId: Schema.decodeUnknownSync(UserId)(42),
  email: "admin@inline.chat",
  firstName: "Inline",
  lastName: "Admin",
  passwordSet: true,
  totpEnabled: true,
  stepUpAt: new Date(),
  ...overrides,
})

const success = () =>
  Effect.succeed({
    kind: "json" as const,
    body: { ok: true as const },
  })

const makeOperations = (
  probe: Probe,
  overrides: Partial<AdminOperationsShape> = {},
): AdminOperationsShape => {
  const called = (name: string) => {
    probe.calls.push(name)
    return success()
  }

  return {
    devLogin: () => called("devLogin"),
    sendEmailCode: () => called("sendEmailCode"),
    verifyEmailCode: () =>
      called("verifyEmailCode"),
    login: () => called("login"),
    setPassword: () => called("setPassword"),
    setupTotp: () => called("setupTotp"),
    verifyTotp: () => called("verifyTotp"),
    stepUp: () => called("stepUp"),
    logout: () => called("logout"),
    me: () => {
      probe.calls.push("me")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          user: {
            id: Schema.decodeUnknownSync(UserId)(42),
            email: "admin@inline.chat",
            firstName: "Inline",
            lastName: "Admin",
          },
          setup: {
            passwordSet: true,
            totpEnabled: true,
          },
          session: {
            stepUpAt: new Date().toISOString(),
          },
        },
      })
    },
    technicalMetrics: () =>
      called("technicalMetrics"),
    appMetrics: () => called("appMetrics"),
    overviewMetrics: () =>
      called("overviewMetrics"),
    activeUsers: () => called("activeUsers"),
    waitlist: () => {
      probe.calls.push("waitlist")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          count: 0,
          entries: [],
        },
      })
    },
    reservedUsernames: () => {
      probe.calls.push("reservedUsernames")
      return Effect.succeed({
        kind: "json",
        body: { ok: true, usernames: [] },
      })
    },
    reserveUsername: () => called("reserveUsername"),
    unreserveUsername: () => called("unreserveUsername"),
    emailCampaigns: () => {
      probe.calls.push("emailCampaigns")
      return Effect.succeed({
        kind: "json",
        body: { ok: true, campaigns: [] },
      })
    },
    serverConfig: () => {
      probe.calls.push("serverConfig")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          settings: [{
            key: "email.default_provider",
            label: "Default email provider",
            description: "Provider description",
            environmentName: "INLINE_CONFIG_EMAIL_DEFAULT_PROVIDER",
            allowedValues: ["ses", "resend"],
            value: "ses",
            source: "database",
            databaseValue: "ses",
            databaseVersion: 1,
            databaseUpdatedAt: "2026-08-13T00:00:00.000Z",
            databaseUpdatedByUserId: 42,
          }],
        },
      })
    },
    updateServerConfig: () => {
      probe.calls.push("updateServerConfig")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          setting: {
            key: "email.default_provider",
            label: "Default email provider",
            description: "Provider description",
            environmentName: "INLINE_CONFIG_EMAIL_DEFAULT_PROVIDER",
            allowedValues: ["ses", "resend"],
            value: "resend",
            source: "database",
            databaseValue: "resend",
            databaseVersion: 2,
            databaseUpdatedAt: "2026-08-13T00:01:00.000Z",
            databaseUpdatedByUserId: 42,
          },
        },
      })
    },
    emailProviderStatus: () => called("emailProviderStatus"),
    testEmailProvider: () => {
      probe.calls.push("testEmailProvider")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          provider: "ses",
          recipient: "admin@inline.chat",
          fromAddress: "team@inline.chat",
          replyToAddress: "hi@inline.chat",
          messageId: "test-message-id",
          sentAt: "2026-08-14T00:00:00.000Z",
        },
      })
    },
    previewEmailCampaign: () => called("previewEmailCampaign"),
    createEmailCampaign: () => called("createEmailCampaign"),
    testEmailCampaign: () => called("testEmailCampaign"),
    sendEmailCampaign: () => called("sendEmailCampaign"),
    pauseEmailCampaign: () => called("pauseEmailCampaign"),
    spaces: () => called("spaces"),
    users: () => called("users"),
    avatar: () => called("avatar"),
    userDetail: () => called("userDetail"),
    invites: () => called("invites"),
    generateInvites: () => {
      probe.calls.push("generateInvites")
      return Effect.succeed({
        kind: "json",
        body: {
          ok: true,
          codes: ["A1B2C3D4"],
        },
      })
    },
    grantInvites: () => called("grantInvites"),
    revokeSession: () =>
      called("revokeSession"),
    updateUser: () => called("updateUser"),
    billingDetail: () => called("billingDetail"),
    addBillingWalletEntry: () =>
      called("addBillingWalletEntry"),
    setBillingPlan: () => called("setBillingPlan"),
    endBillingPlan: () => called("endBillingPlan"),
    recordBillingPayment: () =>
      called("recordBillingPayment"),
    startBillingCreditPlan: () =>
      called("startBillingCreditPlan"),
    financials: () => called("financials"),
    ...overrides,
  }
}

const makeKernel = (
  options: {
    readonly probe?: Probe | undefined
    readonly operations?:
      | Partial<AdminOperationsShape>
      | undefined
    readonly sessionFailure?: unknown | undefined
  } = {},
) => {
  const probe =
    options.probe ??
    ({
      calls: [],
      sessionTokens: [],
      session: session(),
    } satisfies Probe)
  const reports: Array<
    UnexpectedErrorReport<unknown>
  > = []
  const sessionStore = Layer.succeed(
    AdminSessionStore,
    {
      lookup: (token) =>
        Effect.sync(() => {
          probe.sessionTokens.push(token)
        }).pipe(
          Effect.andThen(
            options.sessionFailure === undefined
              ? Effect.succeed(probe.session)
              : Effect.fail(
                  new AdminSessionLookupFailure({
                    cause: options.sessionFailure,
                  }),
                ),
          ),
        ),
    },
  )
  const security = Layer.mergeAll(
    AdminAvatarAuthenticationLive,
    AdminAvatarOriginGuardLive,
    AdminAvatarSetupCompleteLive,
    AdminOriginGuardLive,
    AdminAuthenticationLive,
    AdminSetupCompleteLive,
    AdminRecentStepUpLive,
  ).pipe(Layer.provideMerge(sessionStore))
  const dependencies = Layer.mergeAll(
    Layer.succeed(
      AdminOperations,
      makeOperations(probe, options.operations),
    ),
    security,
    Layer.succeed(ErrorReporter, {
      report: (report) =>
        Effect.sync(() => {
          reports.push(report)
        }),
    }),
  )
  const platformApi = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AdminApiGroup)
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: AdminRouteGroup.handlers.pipe(
        Layer.provide(dependencies),
      ),
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: makeBotApiBase(
          "https://api.inline.chat",
        ),
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: Layer.empty,
    }),
    middleware: {
      isProduction: false,
    },
  }).pipe(
    Layer.provide(HttpServer.layerServices),
    Layer.provide(EffectErrorReporter.layer([])),
    Layer.provide(ErrorReporter.Noop),
  )
  const webHandler = HttpRouter.toWebHandler(
    application,
    { disableLogger: true },
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(
        request,
        Context.empty() as unknown as Context.Context<unknown>,
      ),
    probe,
    reports,
  }
}

const withKernel = async (
  run: (
    kernel: ReturnType<typeof makeKernel>,
  ) => Promise<void>,
  options?: Parameters<typeof makeKernel>[0],
) => {
  const kernel = makeKernel(options)
  try {
    await run(kernel)
  } finally {
    await kernel.dispose()
  }
}

const adminRequest = (
  path: string,
  init: RequestInit = {},
) =>
  new Request(`http://inline.test${path}`, {
    ...init,
    headers: {
      origin: "https://admin.inline.chat",
      cookie: "inline_admin_session=test-token",
      ...init.headers,
    },
  })

describe("AdminRouteGroup", () => {
  it("documents the complete current Admin route and method surface", () => {
    const spec = OpenApi.fromApi(
      makePlatformApiBase(
        "https://api.inline.chat",
      ).add(AdminApiGroup),
    )
    assertValidOpenApiDocument(
      spec,
      "Slice 7 Admin OpenAPI",
    )

    const routes = Object.entries(spec.paths)
      .flatMap(([path, methods]) =>
        Object.keys(methods)
          .filter((method) =>
            [
              "get",
              "post",
              "put",
              "patch",
              "delete",
            ].includes(method),
          )
          .map(
            (method) =>
              `${method.toUpperCase()} ${path}`,
          ),
      )
      .sort()

    expect(routes).toEqual(
      [
        "DELETE /admin/reserved-usernames",
        "GET /admin/auth/totp/setup",
        "GET /admin/email-campaigns",
        "GET /admin/email-provider-status",
        "GET /admin/financials",
        "GET /admin/invites",
        "GET /admin/me",
        "GET /admin/metrics/active-users",
        "GET /admin/metrics/app",
        "GET /admin/metrics/overview",
        "GET /admin/metrics/technical",
        "GET /admin/reserved-usernames",
        "GET /admin/server-config",
        "GET /admin/spaces",
        "GET /admin/spaces/{id}/billing",
        "GET /admin/users",
        "GET /admin/users/{id}",
        "GET /admin/users/{id}/avatar",
        "GET /admin/users/{id}/billing",
        "GET /admin/waitlist",
        "POST /admin/auth/login",
        "POST /admin/auth/dev-login",
        "POST /admin/auth/logout",
        "POST /admin/auth/send-email-code",
        "POST /admin/auth/set-password",
        "POST /admin/auth/step-up",
        "POST /admin/auth/totp/verify",
        "POST /admin/auth/verify-email-code",
        "POST /admin/email-campaigns",
        "POST /admin/email-campaigns/preview",
        "POST /admin/email-campaigns/{id}/pause",
        "POST /admin/email-campaigns/{id}/send",
        "POST /admin/email-campaigns/{id}/test",
        "POST /admin/email-provider-test",
        "POST /admin/invites/generate",
        "POST /admin/reserved-usernames",
        "POST /admin/spaces/{id}/billing/credit-plan",
        "POST /admin/spaces/{id}/billing/payment",
        "POST /admin/spaces/{id}/billing/plan",
        "POST /admin/spaces/{id}/billing/plan/end",
        "POST /admin/spaces/{id}/billing/wallet",
        "POST /admin/users/{id}/billing/credit-plan",
        "POST /admin/users/{id}/billing/payment",
        "POST /admin/users/{id}/billing/plan",
        "POST /admin/users/{id}/billing/plan/end",
        "POST /admin/users/{id}/billing/wallet",
        "POST /admin/users/{id}/invites",
        "POST /admin/users/{id}/sessions/{sessionId}/revoke",
        "POST /admin/users/{id}/update",
        "PUT /admin/server-config",
      ].sort(),
    )

    expect(
      spec.paths["/admin/auth/login"]?.post
        ?.security,
    ).toEqual([])
    expect(
      spec.paths["/admin/me"]?.get?.security,
    ).toEqual([
      {
        adminSession: [],
      },
    ])
    expect(
      spec.paths["/admin/users/{id}/avatar"]?.get
        ?.responses?.["503"],
    ).toBeDefined()
  })

  it("defines admin session cookie directives without changing the token", () => {
    expect(adminSessionCookie("42:INtoken")).toEqual({
      value: "42:INtoken",
      maxAgeSeconds: 259_200,
    })
    expect(clearedAdminSessionCookie()).toEqual({
      value: "",
      maxAgeSeconds: 0,
    })
  })

  it("sets and reads the admin security cookie through Effect HTTP primitives", async () => {
    await withKernel(
      async ({ handler, probe }) => {
        const login = await handler(
          adminRequest("/admin/auth/login", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "admin@inline.chat",
              password: "correct horse battery staple",
            }),
          }),
        )
        expect(login.status).toBe(200)
        const setCookie = login.headers.get("set-cookie")
        expect(setCookie).toContain(
          "inline_admin_session=",
        )
        expect(setCookie).toContain("HttpOnly")
        expect(setCookie).toContain("SameSite=Strict")
        expect(setCookie).toContain("Path=/")
        expect(setCookie).toContain("Max-Age=259200")
        expect(setCookie).not.toContain("Secure")
        // Omitting Domain makes the cookie host-only to the Admin API host.
        expect(setCookie).not.toContain("Domain=")

        const cookie = setCookie?.split(";", 1)[0]
        expect(cookie).toBeDefined()
        const me = await handler(
          adminRequest("/admin/me", {
            headers: {
              cookie: cookie!,
            },
          }),
        )
        expect(me.status).toBe(200)
        expect(probe.sessionTokens.at(-1)).toBe(
          "42:INtoken",
        )
      },
      {
        operations: {
          login: () =>
            Effect.succeed({
              kind: "json",
              body: { ok: true },
              sessionCookie:
                adminSessionCookie("42:INtoken"),
            }),
        },
      },
    )
  })

  it("clears all session-cookie attributes and marks production cookies secure", async () => {
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/auth/logout", {
            method: "POST",
          }),
        )
        expect(response.status).toBe(200)
        const setCookie =
          response.headers.get("set-cookie")
        expect(setCookie).toContain(
          "inline_admin_session=",
        )
        expect(setCookie).toContain("Max-Age=0")
        expect(setCookie).toContain("HttpOnly")
        expect(setCookie).toContain("SameSite=Strict")
        expect(setCookie).toContain("Path=/")
      },
      {
        operations: {
          logout: () =>
            Effect.succeed({
              kind: "json",
              body: { ok: true },
              sessionCookie:
                clearedAdminSessionCookie(),
            }),
        },
      },
    )

    const previousNodeEnv =
      process.env["NODE_ENV"]
    process.env["NODE_ENV"] =
      "production"
    try {
      await withKernel(
        async ({ handler }) => {
          const response = await handler(
            adminRequest("/admin/auth/login", {
              method: "POST",
              headers: {
                "content-type":
                  "application/json",
              },
              body: JSON.stringify({
                email: "admin@inline.chat",
                password: "correct",
              }),
            }),
          )
          expect(
            response.headers.get("set-cookie"),
          ).toContain("Secure")
        },
        {
          operations: {
            login: () =>
              Effect.succeed({
                kind: "json",
                body: { ok: true },
                sessionCookie:
                  adminSessionCookie("secure-token"),
              }),
          },
        },
      )
    } finally {
      if (previousNodeEnv === undefined) {
        Reflect.deleteProperty(
          process.env,
          "NODE_ENV",
        )
      } else {
        process.env["NODE_ENV"] =
          previousNodeEnv
      }
    }
  })

  it("orders authentication, setup, and step-up before body decoding and stateful operations", async () => {
    const noSession: Probe = {
      calls: [],
      sessionTokens: [],
      session: null,
    }
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/auth/set-password", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          }),
        )
        expect({
          status: response.status,
          body: await response.json(),
        }).toEqual({
          status: 401,
          body: {
            ok: false,
            error: "unauthorized",
          },
        })
        expect(noSession.calls).toEqual([])
      },
      { probe: noSession },
    )

    const incomplete: Probe = {
      calls: [],
      sessionTokens: [],
      session: session({
        passwordSet: false,
        totpEnabled: false,
        stepUpAt: null,
      }),
    }
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/email-provider-test", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          }),
        )
        expect(response.status).toBe(403)
        expect(await response.json()).toEqual({
          ok: false,
          error: "setup_required",
        })
        expect(incomplete.calls).toEqual([])
      },
      { probe: incomplete },
    )

    const staleStepUp: Probe = {
      calls: [],
      sessionTokens: [],
      session: session({
        stepUpAt: new Date(0),
      }),
    }
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/email-provider-test", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: "{}",
          }),
        )
        expect(response.status).toBe(403)
        expect(await response.json()).toEqual({
          ok: false,
          error: "step_up_required",
        })
        expect(staleStepUp.calls).toEqual([])
      },
      { probe: staleStepUp },
    )
  })

  it("runs the origin guard before authentication, policy, decoding, and operations", async () => {
    const previousNodeEnv =
      process.env["NODE_ENV"]
    process.env["NODE_ENV"] =
      "production"
    try {
      const probe: Probe = {
        calls: [],
        sessionTokens: [],
        session: null,
      }
      await withKernel(
        async ({ handler }) => {
          const jsonResponse = await handler(
            new Request(
              "http://inline.test/admin/invites/generate",
              {
                method: "POST",
                headers: {
                  origin: "https://attacker.example",
                  "content-type":
                    "application/json",
                },
                body: "{",
              },
            ),
          )
          expect(jsonResponse.status).toBe(403)
          expect(await jsonResponse.json()).toEqual({
            ok: false,
            error: "origin_not_allowed",
          })

          const avatarResponse = await handler(
            new Request(
              "http://inline.test/admin/users/no/avatar",
              {
                headers: {
                  origin: "https://attacker.example",
                },
              },
            ),
          )
          expect(avatarResponse.status).toBe(403)
          expect(await avatarResponse.text()).toBe("")
          expect(
            avatarResponse.headers.get("content-type"),
          ).toBeNull()
          expect(probe.sessionTokens).toEqual([])
          expect(probe.calls).toEqual([])
        },
        { probe },
      )
    } finally {
      if (previousNodeEnv === undefined) {
        Reflect.deleteProperty(
          process.env,
          "NODE_ENV",
        )
      } else {
        process.env["NODE_ENV"] =
          previousNodeEnv
      }
    }
  })

  it("serves representative public, authenticated, setup, and step-up routes", async () => {
    await withKernel(
      async ({ handler, probe }) => {
        const me = await handler(
          adminRequest("/admin/me"),
        )
        expect(me.status).toBe(200)
        expect(await me.json()).toMatchObject({
          ok: true,
          user: { id: 42 },
        })

        const waitlist = await handler(
          adminRequest(
            "/admin/waitlist?query=inline",
          ),
        )
        expect(waitlist.status).toBe(200)
        expect(await waitlist.json()).toEqual({
          ok: true,
          count: 0,
          entries: [],
        })

        const campaigns = await handler(
          adminRequest("/admin/email-campaigns"),
        )
        expect(campaigns.status).toBe(200)
        expect(await campaigns.json()).toEqual({
          ok: true,
          campaigns: [],
        })

        const config = await handler(
          adminRequest("/admin/server-config"),
        )
        expect(config.status).toBe(200)
        expect(await config.json()).toMatchObject({
          ok: true,
          settings: [{
            key: "email.default_provider",
            value: "ses",
            source: "database",
          }],
        })

        const updatedConfig = await handler(
          adminRequest("/admin/server-config", {
            method: "PUT",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              key: "email.default_provider",
              value: "resend",
              expectedVersion: 1,
            }),
          }),
        )
        expect(updatedConfig.status).toBe(200)

        const providerTest = await handler(
          adminRequest("/admin/email-provider-test", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({ provider: "ses" }),
          }),
        )
        expect(providerTest.status).toBe(200)
        expect(await providerTest.json()).toEqual({
          ok: true,
          provider: "ses",
          recipient: "admin@inline.chat",
          fromAddress: "team@inline.chat",
          replyToAddress: "hi@inline.chat",
          messageId: "test-message-id",
          sentAt: "2026-08-14T00:00:00.000Z",
        })

        const generated = await handler(
          adminRequest("/admin/invites/generate", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({ count: 1 }),
          }),
        )
        expect(generated.status).toBe(200)
        expect(await generated.json()).toEqual({
          ok: true,
          codes: ["A1B2C3D4"],
        })
        expect(probe.calls).toEqual([
          "me",
          "waitlist",
          "emailCampaigns",
          "serverConfig",
          "updateServerConfig",
          "testEmailProvider",
          "generateInvites",
        ])
      },
    )
  })

  it("validates Admin responses after JSON omits undefined properties", async () => {
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest(
            "/admin/auth/send-email-code",
            {
              method: "POST",
              headers: {
                "content-type":
                  "application/json",
              },
              body: JSON.stringify({
                email: "admin@inline.chat",
              }),
            },
          ),
        )

        expect(response.status).toBe(200)
        expect(await response.json()).toEqual({
          ok: true,
        })
      },
      {
        operations: {
          sendEmailCode: () =>
            Effect.succeed({
              kind: "json",
              body: {
                ok: true,
                challengeToken: undefined,
              },
            }),
        },
      },
    )
  })

  it("returns sanitized validation failures without invoking an operation", async () => {
    await withKernel(
      async ({ handler, probe }) => {
        const response = await handler(
          adminRequest("/admin/auth/login", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              email: "admin@inline.chat",
              password: 42,
            }),
          }),
        )
        expect(response.status).toBe(422)
        const text = await response.text()
        expect(text).not.toContain(
          "admin@inline.chat",
        )
        expect(text).not.toContain("password")
        expect(probe.calls).toEqual([])
      },
    )
  })

  it("preserves route-specific path errors and intentionally rejects unsafe IDs", async () => {
    await withKernel(
      async ({ handler, probe }) => {
        const avatar = await handler(
          adminRequest(
            "/admin/users/not-a-user/avatar",
          ),
        )
        expect(avatar.status).toBe(400)
        expect(await avatar.text()).toBe("")
        expect(
          avatar.headers.get("content-type"),
        ).toBeNull()

        for (const path of [
          "/admin/users/not-a-user",
          // Intentional correction: the legacy detail/update routes accepted
          // every finite number, including values no valid Inline ID can use.
          "/admin/users/-1",
          "/admin/users/1.5",
        ]) {
          const response = await handler(
            adminRequest(path),
          )
          expect({
            status: response.status,
            body: await response.json(),
          }).toEqual({
            status: 400,
            body: {
              ok: false,
              error: "invalid_user",
            },
          })
        }

        const grant = await handler(
          adminRequest(
            "/admin/users/not-a-user/invites",
            {
              method: "POST",
              headers: {
                "content-type":
                  "application/json",
              },
              body: JSON.stringify({ count: 1 }),
            },
          ),
        )
        expect(await grant.json()).toEqual({
          ok: false,
          error: "invalid_user",
        })
        expect(grant.status).toBe(400)

        const revoke = await handler(
          adminRequest(
            "/admin/users/1/sessions/not-a-session/revoke",
            { method: "POST" },
          ),
        )
        expect(await revoke.json()).toEqual({
          ok: false,
          error: "invalid_session",
        })
        expect(revoke.status).toBe(400)

        const update = await handler(
          adminRequest(
            "/admin/users/not-a-user/update",
            {
              method: "POST",
              headers: {
                "content-type":
                  "application/json",
              },
              body: JSON.stringify({
                firstName: "Inline",
              }),
            },
          ),
        )
        expect(await update.json()).toEqual({
          ok: false,
          error: "invalid_user",
        })
        expect(update.status).toBe(400)

        const invalidQuery = await handler(
          adminRequest(
            "/admin/metrics/active-users?period=month",
          ),
        )
        expect(invalidQuery.status).toBe(422)
        expect(await invalidQuery.json()).toMatchObject({
          type: "validation",
          on: "query",
        })
        expect(probe.calls).toEqual([])
      },
    )
  })

  it("routes user and space billing to subject-shaped operations behind the right guards", async () => {
    const subjects: Array<[string, unknown]> = []
    const subscription = {
      id: 3,
      userId: null,
      spaceId: 9,
      plan: "team",
      interval: "none",
      funding: "comp",
      status: "active",
      seats: 4,
      paidThrough: null,
      cancelAtPeriodEnd: false,
      payerUserId: null,
      stripeSubscriptionId: null,
      livemode: false,
      chargeAmount: null,
      chargeCurrency: null,
      chargeInterval: null,
      chargeUsdCents: null,
      note: null,
      createdAt: "2026-11-01T00:00:00.000Z",
      updatedAt: "2026-11-01T00:00:00.000Z",
      endedAt: null,
    }
    await withKernel(
      async ({ handler, probe }) => {
        const detail = await handler(
          adminRequest("/admin/spaces/9/billing"),
        )
        expect(detail.status).toBe(200)
        expect(await detail.json()).toEqual({
          ok: true,
          isPro: true,
          live: subscription,
          subscriptions: [subscription],
          wallet: { btc: 150_000 },
          walletEntries: [],
          orders: [],
        })

        const invalidSpace = await handler(
          adminRequest(
            "/admin/spaces/not-a-space/billing/wallet",
            {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: JSON.stringify({
                currency: "usd",
                amount: 500,
                kind: "admin_topup",
              }),
            },
          ),
        )
        expect(invalidSpace.status).toBe(400)
        expect(await invalidSpace.json()).toEqual({
          ok: false,
          error: "invalid_space",
        })

        const invalidPlan = await handler(
          adminRequest("/admin/users/5/billing/plan", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              plan: "gold",
              funding: "comp",
              paidThrough: null,
            }),
          }),
        )
        expect(invalidPlan.status).toBe(422)

        const stripeManaged = await handler(
          adminRequest("/admin/users/5/billing/plan/end", {
            method: "POST",
          }),
        )
        expect(stripeManaged.status).toBe(409)
        expect(await stripeManaged.json()).toEqual({
          ok: false,
          error: "stripe_managed",
        })

        expect(subjects).toEqual([
          ["billingDetail", { spaceId: 9 }],
          ["endBillingPlan", { userId: 5 }],
        ])
        expect(probe.calls).toEqual([])
      },
      {
        operations: {
          billingDetail: (subject) => {
            subjects.push(["billingDetail", subject])
            return Effect.succeed({
              kind: "json",
              body: {
                ok: true,
                isPro: true,
                live: subscription,
                subscriptions: [subscription],
                wallet: { btc: 150_000 },
                walletEntries: [],
                orders: [],
              },
            })
          },
          endBillingPlan: (subject) => {
            subjects.push(["endBillingPlan", subject])
            return Effect.fail(
              new AdminRejected({
                status: 409,
                error: "stripe_managed",
              }),
            )
          },
        },
      },
    )

    const staleStepUp: Probe = {
      calls: [],
      sessionTokens: [],
      session: session({
        stepUpAt: new Date(0),
      }),
    }
    await withKernel(
      async ({ handler }) => {
        const read = await handler(
          adminRequest("/admin/users/5/billing"),
        )
        expect(read.status).toBe(200)

        const write = await handler(
          adminRequest("/admin/users/5/billing/wallet", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              currency: "btc",
              amount: 10_000,
              kind: "btc_topup",
            }),
          }),
        )
        expect(write.status).toBe(403)
        expect(await write.json()).toEqual({
          ok: false,
          error: "step_up_required",
        })
        expect(staleStepUp.calls).toEqual([])
      },
      {
        probe: staleStepUp,
        operations: {
          billingDetail: () =>
            Effect.succeed({
              kind: "json",
              body: {
                ok: true,
                isPro: false,
                live: null,
                subscriptions: [],
                wallet: {},
                walletEntries: [],
                orders: [],
              },
            }),
        },
      },
    )
  })

  it("routes payments, credit plans and the financials overview behind the right guards", async () => {
    const payments: Array<[unknown, unknown]> = []
    const creditPlans: Array<[unknown, unknown]> = []
    const credit = {
      id: 11,
      userId: null,
      spaceId: 9,
      currency: "btc",
      amount: 50_000,
      kind: "btc_topup",
      reference: "fake-tx",
      subscriptionId: null,
      adminId: 2,
      occurredAt: "2026-10-01T12:00:00.000Z",
      periodStart: null,
      usdCents: 30_000,
      createdAt: "2026-11-01T00:00:00.000Z",
    }
    const creditPlan = {
      id: 12,
      userId: null,
      spaceId: 9,
      plan: "business",
      interval: "none",
      funding: "wallet",
      status: "active",
      seats: 3,
      paidThrough: "2026-11-01T12:00:00.000Z",
      cancelAtPeriodEnd: false,
      payerUserId: null,
      stripeSubscriptionId: null,
      livemode: false,
      chargeAmount: null,
      chargeCurrency: "btc",
      chargeInterval: "month",
      chargeUsdCents: 9_000,
      note: null,
      createdAt: "2026-11-01T00:00:00.000Z",
      updatedAt: "2026-11-01T00:00:00.000Z",
      endedAt: null,
    }
    const financials = {
      ok: true,
      btcUsd: 60_000,
      mrr: {
        mrrUsdCents: 9_000,
        arrUsdCents: 108_000,
        stripeUsdCents: 0,
        creditUsdCents: 9_000,
        payingPlans: 1,
        compPlans: 0,
        unpricedPlans: 0,
        testModeUsdCents: 0,
        testModePlans: 0,
        creditMonthlyByCurrency: { btc: 10_000 },
      },
      live: [
        {
          ...creditPlan,
          isPro: true,
          creditBalance: 40_000,
          creditRunsOutAt: "2027-03-01T12:00:00.000Z",
          monthlyUsdCents: 9_000,
          userName: null,
          username: null,
          spaceName: "Fake Space",
        },
      ],
      balances: [
        {
          userId: null,
          spaceId: 9,
          currency: "btc",
          balance: 50_000,
          userName: null,
          username: null,
          spaceName: "Fake Space",
        },
      ],
      entries: [
        {
          ...credit,
          userName: null,
          username: null,
          spaceName: "Fake Space",
        },
      ],
      orders: [],
      receivedOffStripe: { btc: 50_000 },
    }
    await withKernel(
      async ({ handler, probe }) => {
        const payment = await handler(
          adminRequest("/admin/spaces/9/billing/payment", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              currency: "btc",
              amount: 50_000,
              reference: "fake-tx",
              occurredAt: "2026-10-01T12:00:00.000Z",
              usdCents: 30_000,
              plan: {
                plan: "business",
                seats: 3,
                chargeInterval: "month",
                chargeUsdCents: 9_000,
                startAt: "2026-10-01T12:00:00.000Z",
              },
            }),
          }),
        )
        expect(payment.status).toBe(200)
        expect(await payment.json()).toEqual({
          ok: true,
          credit,
          subscription: creditPlan,
        })

        const oldPlanShape = await handler(
          adminRequest("/admin/spaces/9/billing/payment", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              currency: "btc",
              amount: 50_000,
              plan: {
                plan: "business",
                paidThrough: null,
              },
            }),
          }),
        )
        expect(oldPlanShape.status).toBe(422)

        const started = await handler(
          adminRequest("/admin/users/5/billing/credit-plan", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              plan: "pro",
              chargeCurrency: "usd",
              chargeInterval: "year",
            }),
          }),
        )
        expect(started.status).toBe(200)
        expect(await started.json()).toEqual({
          ok: true,
          subscription: creditPlan,
        })

        for (const invalid of [
          { plan: "pro", chargeAmount: 1_000, chargeCurrency: "eur", chargeInterval: "month" },
          { plan: "pro", chargeAmount: 1_000, chargeCurrency: "usd", chargeInterval: "week" },
          { plan: "pro", chargeAmount: "100", chargeCurrency: "usd", chargeInterval: "month" },
        ]) {
          const rejected = await handler(
            adminRequest("/admin/spaces/9/billing/credit-plan", {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: JSON.stringify(invalid),
            }),
          )
          expect(rejected.status).toBe(422)
        }

        const stripeManaged = await handler(
          adminRequest("/admin/spaces/9/billing/credit-plan", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              plan: "team",
              seats: 2,
              chargeAmount: 4_000,
              chargeCurrency: "usd",
              chargeInterval: "month",
            }),
          }),
        )
        expect(stripeManaged.status).toBe(409)
        expect(await stripeManaged.json()).toEqual({
          ok: false,
          error: "stripe_managed",
        })

        const unknownCurrency = await handler(
          adminRequest("/admin/users/5/billing/payment", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              currency: "eur",
              amount: 100,
            }),
          }),
        )
        expect(unknownCurrency.status).toBe(422)

        const overview = await handler(
          adminRequest("/admin/financials"),
        )
        expect(overview.status).toBe(200)
        expect(await overview.json()).toEqual(financials)

        expect(payments).toEqual([
          [
            { spaceId: 9 },
            {
              currency: "btc",
              amount: 50_000,
              reference: "fake-tx",
              occurredAt: "2026-10-01T12:00:00.000Z",
              usdCents: 30_000,
              plan: {
                plan: "business",
                seats: 3,
                chargeInterval: "month",
                chargeUsdCents: 9_000,
                startAt: "2026-10-01T12:00:00.000Z",
              },
            },
          ],
        ])
        expect(creditPlans).toEqual([
          [
            { userId: 5 },
            {
              plan: "pro",
              chargeCurrency: "usd",
              chargeInterval: "year",
            },
          ],
          [
            { spaceId: 9 },
            {
              plan: "team",
              seats: 2,
              chargeAmount: 4_000,
              chargeCurrency: "usd",
              chargeInterval: "month",
            },
          ],
        ])
        expect(probe.calls).toEqual([])
      },
      {
        operations: {
          recordBillingPayment: (subject, input) => {
            payments.push([subject, input])
            return Effect.succeed({
              kind: "json",
              body: { ok: true, credit, subscription: creditPlan },
            })
          },
          startBillingCreditPlan: (subject, input) => {
            creditPlans.push([subject, input])
            return subject.spaceId !== undefined
              ? Effect.fail(
                  new AdminRejected({
                    status: 409,
                    error: "stripe_managed",
                  }),
                )
              : Effect.succeed({
                  kind: "json",
                  body: { ok: true, subscription: creditPlan },
                })
          },
          financials: () =>
            Effect.succeed({
              kind: "json",
              body: financials,
            }),
        },
      },
    )

    const staleStepUp: Probe = {
      calls: [],
      sessionTokens: [],
      session: session({
        stepUpAt: new Date(0),
      }),
    }
    await withKernel(
      async ({ handler }) => {
        const read = await handler(
          adminRequest("/admin/financials"),
        )
        expect(read.status).toBe(200)

        const write = await handler(
          adminRequest("/admin/users/5/billing/payment", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              currency: "usd",
              amount: 1_000,
            }),
          }),
        )
        expect(write.status).toBe(403)
        expect(await write.json()).toEqual({
          ok: false,
          error: "step_up_required",
        })

        const creditPlanWrite = await handler(
          adminRequest("/admin/spaces/9/billing/credit-plan", {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify({
              plan: "team",
              chargeAmount: 4_000,
              chargeCurrency: "usd",
              chargeInterval: "month",
            }),
          }),
        )
        expect(creditPlanWrite.status).toBe(403)
        expect(await creditPlanWrite.json()).toEqual({
          ok: false,
          error: "step_up_required",
        })
        expect(staleStepUp.calls).toEqual([])
      },
      {
        probe: staleStepUp,
        operations: {
          financials: () =>
            Effect.succeed({
              kind: "json",
              body: {
                ok: true,
                btcUsd: null,
                mrr: {
                  mrrUsdCents: 0,
                  arrUsdCents: 0,
                  stripeUsdCents: 0,
                  creditUsdCents: 0,
                  payingPlans: 0,
                  compPlans: 0,
                  unpricedPlans: 0,
                  testModeUsdCents: 0,
                  testModePlans: 0,
                  creditMonthlyByCurrency: {},
                },
                live: [],
                balances: [],
                entries: [],
                orders: [],
                receivedOffStripe: {},
              },
            }),
        },
      },
    )

    await withKernel(
      async ({ handler }) => {
        const signedOut = await handler(
          adminRequest("/admin/financials"),
        )
        expect(signedOut.status).toBe(401)
      },
      {
        probe: {
          calls: [],
          sessionTokens: [],
          session: null,
        },
      },
    )
  })

  it("preserves empty avatar failures and serves dynamic image metadata", async () => {
    const noSession: Probe = {
      calls: [],
      sessionTokens: [],
      session: null,
    }
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/users/1/avatar"),
        )
        expect(response.status).toBe(401)
        expect(await response.text()).toBe("")
        expect(
          response.headers.get("content-type"),
        ).toBeNull()
      },
      { probe: noSession },
    )

    const incomplete: Probe = {
      calls: [],
      sessionTokens: [],
      session: session({
        passwordSet: false,
      }),
    }
    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/users/1/avatar"),
        )
        expect(response.status).toBe(403)
        expect(await response.text()).toBe("")
      },
      { probe: incomplete },
    )

    for (const status of [404, 503]) {
      await withKernel(
        async ({ handler }) => {
          const response = await handler(
            adminRequest(
              "/admin/users/1/avatar",
            ),
          )
          expect(response.status).toBe(status)
          expect(await response.text()).toBe("")
          expect(
            response.headers.get("set-cookie"),
          ).toBeNull()
        },
        {
          operations: {
            avatar: () =>
              Effect.fail(
                new AdminRejected({
                  status,
                  error:
                    status === 404
                      ? "not_found"
                      : "storage_unavailable",
                  empty: true,
                }),
              ),
          },
        },
      )
    }

    await withKernel(
      async ({ handler }) => {
        const response = await handler(
          adminRequest("/admin/users/1/avatar"),
        )
        expect(response.status).toBe(200)
        expect(
          response.headers.get("content-type"),
        ).toBe("image/webp")
        expect(
          response.headers.get("cache-control"),
        ).toBe("private, max-age=300")
        expect(
          Array.from(
            new Uint8Array(
              await response.arrayBuffer(),
            ),
          ),
        ).toEqual([82, 73, 70, 70])
      },
      {
        operations: {
          avatar: () =>
            Effect.succeed({
              kind: "raw",
              body: new Uint8Array([
                82,
                73,
                70,
                70,
              ]),
              headers: {
                "content-type": "image/webp",
                "cache-control":
                  "private, max-age=300",
              },
            }),
        },
      },
    )
  })

  it("reports an unexpected operation failure once and keeps its cause private", async () => {
    const privateCause = new Error(
      "database token=must-not-leak",
    )
    await withKernel(
      async ({ handler, reports }) => {
        const response = await handler(
          adminRequest("/admin/me"),
        )
        expect(response.status).toBe(500)
        expect(await response.json()).toEqual({
          ok: false,
          error: "server_error",
        })
        expect(reports).toHaveLength(1)
        expect(reports[0]?.context.operation).toBe(
          "admin.me.repository.lookup",
        )
      },
      {
        operations: {
          me: () =>
            Effect.fail(
              new AdminOperationFailure({
                operation:
                  "admin.me.repository.lookup",
                cause: privateCause,
              }),
            ),
        },
      },
    )
  })

  it("reports an authentication lookup failure once with an opaque 500 response", async () => {
    const privateCause = new Error(
      "session query password=must-not-leak",
    )
    await withKernel(
      async ({ handler, reports }) => {
        const response = await handler(
          adminRequest("/admin/me"),
        )
        expect(response.status).toBe(500)
        expect(await response.json()).toEqual({
          ok: false,
          error: "server_error",
        })
        expect(reports).toHaveLength(1)
        expect(reports[0]?.context.operation).toBe(
          "admin.authentication.lookup",
        )
      },
      {
        sessionFailure: privateCause,
      },
    )
  })

  it("validates successful operation output before serving it", async () => {
    await withKernel(
      async ({ handler, reports }) => {
        const response = await handler(
          adminRequest("/admin/me"),
        )
        expect(response.status).toBe(500)
        expect(await response.json()).toEqual({
          ok: false,
          error: "server_error",
        })
        expect(reports).toHaveLength(1)
        expect(reports[0]?.context.operation).toBe(
          "admin.me",
        )
      },
      {
        operations: {
          me: () =>
            Effect.succeed({
              kind: "json",
              body: { ok: true },
            }),
        },
      },
    )
  })
})
