import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  vi,
} from "vitest"
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
        "GET /admin/auth/totp/setup",
        "GET /admin/invites",
        "GET /admin/me",
        "GET /admin/metrics/active-users",
        "GET /admin/metrics/app",
        "GET /admin/metrics/overview",
        "GET /admin/metrics/technical",
        "GET /admin/spaces",
        "GET /admin/users",
        "GET /admin/users/{id}",
        "GET /admin/users/{id}/avatar",
        "GET /admin/waitlist",
        "POST /admin/auth/login",
        "POST /admin/auth/logout",
        "POST /admin/auth/send-email-code",
        "POST /admin/auth/set-password",
        "POST /admin/auth/step-up",
        "POST /admin/auth/totp/verify",
        "POST /admin/auth/verify-email-code",
        "POST /admin/invites/generate",
        "POST /admin/users/{id}/invites",
        "POST /admin/users/{id}/sessions/{sessionId}/revoke",
        "POST /admin/users/{id}/update",
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

    vi.stubEnv("NODE_ENV", "production")
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
      vi.unstubAllEnvs()
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
          adminRequest("/admin/invites/generate", {
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
          adminRequest("/admin/invites/generate", {
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
    vi.stubEnv("NODE_ENV", "production")
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
      vi.unstubAllEnvs()
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
          "generateInvites",
        ])
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
