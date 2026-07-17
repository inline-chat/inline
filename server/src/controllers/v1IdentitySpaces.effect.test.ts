import { describe, expect, it } from "@effect/vitest"
import { Context, Effect, ErrorReporter as EffectErrorReporter, Layer, Schema } from "effect"
import { ConnectionError_Reason } from "@inline-chat/protocol/core"
import Elysia, { t } from "elysia"
import { HttpRouter, HttpServer } from "effect/unstable/http"
import { ErrorReporter, type ErrorReporterShape } from "../core/errors/errorReporter"
import { defineExecutableHttpApi, makeHttpApplication } from "../core/http/application"
import { defineOpenApiDocument, makeBotApiBase, makePlatformApiBase } from "../core/http/openApi"
import { HttpRequestContext } from "../core/http/requestContext"
import { RequestId } from "../core/helpers/requestId"
import { InlineError } from "../types/errors"
import { handleError } from "./apiErrorHandler"
import { TMakeApiResponse } from "./apiResponse"
import {
  SessionAuthentication,
  SessionAuthenticationFailure,
  SessionAuthenticationRejected,
  makeSessionIdentity,
  type SessionAuthenticationShape,
} from "./plugins.effect"
import {
  makeV1IdentitySpacesOperations,
  type LegacyV1IdentitySpacesOperations,
} from "./v1IdentitySpacesOperationsAdapter.effect"
import {
  V1IdentitySpacesOperationFailure,
  V1IdentitySpacesOperations,
  V1IdentitySpacesPublicError,
  type V1IdentitySpacesOperationsShape,
} from "./v1IdentitySpacesOperations.effect"
import {
  AddMemberResult,
  CheckUsernameResult,
  CreateSpaceResult,
  GetInviteCodesResult,
  GetMeResult,
  GetSpaceMembersResult,
  GetSpaceResult,
  GetSpacesResult,
  GetUserResult,
  LeaveSpaceResult,
  SearchContactsResult,
  UpdateProfilePhotoResult,
  UpdateProfileResult,
  UpdateStatusResult,
} from "./v1IdentitySpacesSchemas.effect"
import {
  makeV1IdentitySpacesRouteGroup,
  type V1IdentitySpacesOperation,
  V1IdentitySpacesApiGroup,
} from "./v1IdentitySpaces.effect"

const decode = <A>(schema: Schema.Decoder<A>, input: unknown): A => Schema.decodeUnknownSync(schema)(input)

const date = 1_700_000_000
const user = {
  id: 42,
  firstName: "Mo",
  username: "mo",
  date,
}
const minUser = {
  id: 43,
  firstName: "Inline",
  username: "inline",
  date,
}
const space = {
  id: 9,
  name: "Inline",
  handle: "inline",
  date,
  creator: true,
  isPublic: false,
}
const member = {
  id: 10,
  userId: 42,
  spaceId: 9,
  role: "owner",
  date,
}

const fixtures = {
  checkUsername: decode(CheckUsernameResult, {
    available: true,
  }),
  getMe: decode(GetMeResult, { user }),
  getUser: decode(GetUserResult, { user: minUser }),
  searchContacts: decode(SearchContactsResult, {
    users: [minUser],
  }),
  updateProfile: decode(UpdateProfileResult, { user }),
  updateProfilePhoto: decode(UpdateProfilePhotoResult, {
    user,
  }),
  updateStatus: decode(UpdateStatusResult, {
    online: true,
    lastOnline: 1_700_000_000_000,
  }),
  createSpace: decode(CreateSpaceResult, {
    space,
    member,
    chats: [
      {
        id: 11,
        type: "thread",
        peer: { threadId: 11 },
        date,
        title: "Main",
        spaceId: 9,
        publicThread: true,
        number: 1,
      },
    ],
    dialogs: [
      {
        peerId: { threadId: 11 },
        chatId: 11,
        spaceId: 9,
        unreadCount: 0,
      },
    ],
  }),
  getSpaces: decode(GetSpacesResult, {
    spaces: [space],
    members: [member],
  }),
  getSpace: decode(GetSpaceResult, {
    space,
    members: [member],
  }),
  getInviteCodes: decode(GetInviteCodesResult, {
    codes: [
      {
        code: "INVITE42",
        redeemed: false,
      },
    ],
  }),
  addMember: decode(AddMemberResult, { member }),
  leaveSpace: decode(LeaveSpaceResult, {
    memberId: 10,
    userId: 42,
  }),
  getSpaceMembers: decode(GetSpaceMembersResult, {
    members: [member],
    users: [minUser],
  }),
} as const

const makeOperations = (
  overrides: Partial<V1IdentitySpacesOperationsShape> = {},
  calls: Array<V1IdentitySpacesOperation> = [],
): V1IdentitySpacesOperationsShape => ({
  checkUsername: () => {
    calls.push("checkUsername")
    return Effect.succeed(fixtures.checkUsername)
  },
  getMe: () => {
    calls.push("getMe")
    return Effect.succeed(fixtures.getMe)
  },
  getUser: () => {
    calls.push("getUser")
    return Effect.succeed(fixtures.getUser)
  },
  searchContacts: () => {
    calls.push("searchContacts")
    return Effect.succeed(fixtures.searchContacts)
  },
  updateProfile: () => {
    calls.push("updateProfile")
    return Effect.succeed(fixtures.updateProfile)
  },
  updateProfilePhoto: () => {
    calls.push("updateProfilePhoto")
    return Effect.succeed(fixtures.updateProfilePhoto)
  },
  updateStatus: () => {
    calls.push("updateStatus")
    return Effect.succeed(fixtures.updateStatus)
  },
  createSpace: () => {
    calls.push("createSpace")
    return Effect.succeed(fixtures.createSpace)
  },
  deleteSpace: () => {
    calls.push("deleteSpace")
    return Effect.void
  },
  getSpaces: () => {
    calls.push("getSpaces")
    return Effect.succeed(fixtures.getSpaces)
  },
  getSpace: () => {
    calls.push("getSpace")
    return Effect.succeed(fixtures.getSpace)
  },
  getInviteCodes: () => {
    calls.push("getInviteCodes")
    return Effect.succeed(fixtures.getInviteCodes)
  },
  addMember: () => {
    calls.push("addMember")
    return Effect.succeed(fixtures.addMember)
  },
  leaveSpace: () => {
    calls.push("leaveSpace")
    return Effect.succeed(fixtures.leaveSpace)
  },
  getSpaceMembers: () => {
    calls.push("getSpaceMembers")
    return Effect.succeed(fixtures.getSpaceMembers)
  },
  savePushNotification: () => {
    calls.push("savePushNotification")
    return Effect.void
  },
  ...overrides,
})

const makeKernel = ({
  errorReporter = {
    report: () => Effect.void,
  },
  operations,
  sessionAuthentication = {
    authenticate: () =>
      Effect.succeed(makeSessionIdentity(42, 7)),
  },
}: {
  readonly errorReporter?: ErrorReporterShape | undefined
  readonly operations: V1IdentitySpacesOperationsShape
  readonly sessionAuthentication?: SessionAuthenticationShape | undefined
}) => {
  const routeGroup = makeV1IdentitySpacesRouteGroup()
  const platformApi = makePlatformApiBase("https://api.inline.chat").add(V1IdentitySpacesApiGroup)
  const botApi = makeBotApiBase("https://api.inline.chat")
  const services = Layer.merge(
    Layer.succeed(V1IdentitySpacesOperations)(operations),
    Layer.succeed(SessionAuthentication)(sessionAuthentication),
  )
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: routeGroup.handlers,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
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
    Layer.provide(Layer.succeed(ErrorReporter, errorReporter)),
    Layer.provide(services),
  )
  const webHandler = HttpRouter.toWebHandler(application, {
    disableLogger: true,
  })
  const context = Context.make(HttpRequestContext, {
    clientIp: "unresolved-client",
    method: "GET",
    path: "/test",
    requestId: RequestId.make("v1-identity-spaces-test"),
    startedAtMillis: 0,
  }).pipe(
    Context.add(V1IdentitySpacesOperations, operations),
    Context.add(SessionAuthentication, sessionAuthentication),
    Context.add(ErrorReporter, errorReporter),
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) => webHandler.handler(request, context),
  }
}

const routeCases: ReadonlyArray<{
  readonly operation: V1IdentitySpacesOperation
  readonly method: string
  readonly input: Readonly<Record<string, unknown>>
}> = [
  {
    operation: "checkUsername",
    method: "checkUsername",
    input: { username: "inline" },
  },
  {
    operation: "getMe",
    method: "getMe",
    input: {},
  },
  {
    operation: "getUser",
    method: "getUser",
    input: { id: 43 },
  },
  {
    operation: "searchContacts",
    method: "searchContacts",
    input: { q: "in", limit: 20 },
  },
  {
    operation: "updateProfile",
    method: "updateProfile",
    input: { firstName: "Mo" },
  },
  {
    operation: "updateProfilePhoto",
    method: "updateProfilePhoto",
    input: { fileUniqueId: "INP123" },
  },
  {
    operation: "updateStatus",
    method: "updateStatus",
    input: { online: true },
  },
  {
    operation: "createSpace",
    method: "createSpace",
    input: { name: "Inline", handle: "inline" },
  },
  {
    operation: "deleteSpace",
    method: "deleteSpace",
    input: { spaceId: 9 },
  },
  {
    operation: "getSpaces",
    method: "getSpaces",
    input: {},
  },
  {
    operation: "getSpace",
    method: "getSpace",
    input: { id: 9 },
  },
  {
    operation: "getInviteCodes",
    method: "getInviteCodes",
    input: {},
  },
  {
    operation: "addMember",
    method: "addMember",
    input: { spaceId: 9, userId: 43 },
  },
  {
    operation: "leaveSpace",
    method: "leaveSpace",
    input: { spaceId: 9 },
  },
  {
    operation: "getSpaceMembers",
    method: "getSpaceMembers",
    input: { spaceId: 9 },
  },
  {
    operation: "savePushNotification",
    method: "savePushNotification",
    input: { applePushToken: "push-token" },
  },
]

const queryString = (input: Readonly<Record<string, unknown>>): string => {
  const query = new URLSearchParams(Object.entries(input).map(([key, value]) => [key, String(value)])).toString()
  return query === "" ? "" : `?${query}`
}

const expectSuccess = async (response: Response) => {
  expect(response.status).toBe(200)
  expect(response.headers.get("content-type")).toContain("application/json")
  expect(response.headers.get("x-request-id")).toBeTruthy()
  expect(await response.json()).toMatchObject({ ok: true })
}

describe("Effect /v1 identity and spaces routes", () => {
  it("serves every retained header, path-token, and POST form", async () => {
    const calls: Array<V1IdentitySpacesOperation> = []
    const tokens: Array<string> = []
    const kernel = makeKernel({
      operations: makeOperations({}, calls),
      sessionAuthentication: {
        authenticate: (token) => {
          tokens.push(token)
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    try {
      for (const testCase of routeCases) {
        const query = queryString(testCase.input)
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/${testCase.method}${query}`, {
              headers: {
                authorization: "Bearer 42:header-token",
              },
            }),
          ),
        )
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/42%3Apath-token/${testCase.method}${query}`, {
              headers: {
                authorization: "Bearer 42:ignored-token",
              },
            }),
          ),
        )
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/${testCase.method}`, {
              method: "POST",
              headers: {
                authorization: "Bearer 42:header-token",
                "content-type": "application/json",
              },
              body: JSON.stringify(testCase.input),
            }),
          ),
        )
      }

      for (const testCase of routeCases) {
        expect(calls.filter((operation) => operation === testCase.operation)).toHaveLength(3)
      }
      expect(tokens.filter((token) => token === "42:path-token")).toHaveLength(routeCases.length)
      expect(tokens).not.toContain("42:ignored-token")
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves Elysia integer coercion and GET boolean coercion", async () => {
    const searchInputs: Array<unknown> = []
    const oracleSearchInputs: Array<unknown> = []
    let statusInput: unknown
    const oracle = new Elysia().post(
      "/v1/searchContacts",
      ({ body }) => {
        oracleSearchInputs.push(body)
        return { ok: true }
      },
      {
        body: t.Object({
          q: t.String(),
          limit: t.Optional(t.Integer()),
        }),
      },
    )
    const operations = makeOperations({
      searchContacts: (input) => {
        searchInputs.push(input)
        return Effect.succeed(fixtures.searchContacts)
      },
      updateStatus: (input) => {
        statusInput = input
        return Effect.succeed(fixtures.updateStatus)
      },
    })
    const kernel = makeKernel({ operations })

    try {
      await expectSuccess(
        await kernel.handler(
          new Request("http://inline.test/v1/searchContacts?q=in&limit=20", {
            headers: {
              authorization: "Bearer 42:token",
            },
          }),
        ),
      )
      await expectSuccess(
        await kernel.handler(
          new Request("http://inline.test/v1/updateStatus?online=false", {
            headers: {
              authorization: "Bearer 42:token",
            },
          }),
        ),
      )
      await expectSuccess(
        await kernel.handler(
          new Request("http://inline.test/v1/searchContacts", {
            method: "POST",
            headers: {
              authorization: "Bearer 42:token",
              "content-type": "application/json",
            },
            body: JSON.stringify({
              q: "in",
              limit: "20",
            }),
          }),
        ),
      )
      await expectSuccess(
        await kernel.handler(
          new Request("http://inline.test/v1/searchContacts", {
            method: "POST",
            headers: {
              authorization: "Bearer 42:token",
              "content-type": "application/x-www-form-urlencoded",
            },
            body: "q=in&limit=20",
          }),
        ),
      )
      const oracleJson = await oracle.handle(
        new Request("http://inline.test/v1/searchContacts", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: JSON.stringify({
            q: "in",
            limit: "20",
          }),
        }),
      )
      const oracleForm = await oracle.handle(
        new Request("http://inline.test/v1/searchContacts", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded",
          },
          body: "q=in&limit=20",
        }),
      )

      expect(searchInputs).toEqual([
        { q: "in", limit: 20 },
        { q: "in", limit: 20 },
        { q: "in", limit: 20 },
      ])
      expect(oracleJson.status).toBe(200)
      expect(oracleForm.status).toBe(200)
      expect(oracleSearchInputs).toEqual(searchInputs.slice(1))
      expect(statusInput).toEqual({ online: false })
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves the legacy POST body boundary before stateful work", async () => {
    const inputs: Array<unknown> = []
    let authenticationCalls = 0
    const operations = makeOperations({
      checkUsername: (input) => {
        inputs.push(input)
        return Effect.succeed(fixtures.checkUsername)
      },
    })
    const kernel = makeKernel({
      operations,
      sessionAuthentication: {
        authenticate: () => {
          authenticationCalls += 1
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })
    const jsonRequest = (body: string) =>
      new Request("http://inline.test/v1/checkUsername", {
        method: "POST",
        headers: {
          authorization: "Bearer 42:token",
          "content-type": "application/json",
        },
        body,
      })
    const formRequest = () =>
      new Request("http://inline.test/v1/checkUsername", {
        method: "POST",
        headers: {
          authorization: "Bearer 42:token",
          "content-type": "application/x-www-form-urlencoded",
        },
        body: "username=inline",
      })
    const multipartRequest = () => {
      const body = new FormData()
      body.set("username", "inline")
      return new Request("http://inline.test/v1/checkUsername", {
        method: "POST",
        headers: {
          authorization: "Bearer 42:token",
        },
        body,
      })
    }

    try {
      await expectSuccess(await kernel.handler(jsonRequest(JSON.stringify({ username: "inline" }))))
      await expectSuccess(await kernel.handler(formRequest()))
      await expectSuccess(await kernel.handler(multipartRequest()))

      const invalidRequests = [
        new Request("http://inline.test/v1/checkUsername", {
          method: "POST",
          headers: {
            authorization: "Bearer 42:token",
            "content-type": "text/plain",
          },
          body: JSON.stringify({ username: "inline" }),
        }),
        new Request("http://inline.test/v1/checkUsername", {
          method: "POST",
          headers: {
            authorization: "Bearer 42:token",
          },
          body: JSON.stringify({ username: "inline" }),
        }),
        new Request("http://inline.test/v1/checkUsername", {
          method: "POST",
          headers: {
            authorization: "Bearer 42:token",
            "content-type": "application/x-www-form-urlencoded",
          },
          body: "username=inline&username=other",
        }),
      ]
      for (const request of invalidRequests) {
        const response = await kernel.handler(request)
        expect(response.status).toBe(400)
        expect(await response.json()).toMatchObject({
          ok: false,
          error: "INVALID_ARGS",
          errorCode: 400,
        })
      }

      const malformed = await kernel.handler(jsonRequest("{"))
      expect(malformed.status).toBe(500)
      expect(await malformed.json()).toEqual({
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      })

      expect(inputs).toEqual([{ username: "inline" }, { username: "inline" }, { username: "inline" }])
      expect(authenticationCalls).toBe(3)
    } finally {
      await kernel.dispose()
    }
  })

  it("matches the current Elysia oracle for POST parsing and envelopes", async () => {
    let legacyCalls = 0
    let replacementCalls = 0
    const legacyInput = t.Object({
      username: t.String(),
    })
    const legacyResult = t.Object({
      available: t.Boolean(),
    })
    const legacy = new Elysia().use(handleError).post(
      "/v1/checkUsername",
      () => {
        legacyCalls += 1
        return {
          ok: true as const,
          result: { available: true },
        }
      },
      {
        body: legacyInput,
        response: TMakeApiResponse(legacyResult),
      },
    )
    const kernel = makeKernel({
      operations: makeOperations({
        checkUsername: () => {
          replacementCalls += 1
          return Effect.succeed(fixtures.checkUsername)
        },
      }),
    })
    const request = (body: BodyInit | undefined, contentType?: string) =>
      new Request("http://inline.test/v1/checkUsername", {
        method: "POST",
        headers: {
          authorization: "Bearer 42:token",
          ...(contentType === undefined ? {} : { "content-type": contentType }),
        },
        body,
      })
    const cases = [
      {
        name: "JSON",
        make: () => request(JSON.stringify({ username: "inline" }), "application/json"),
      },
      {
        name: "form-urlencoded",
        make: () => request("username=inline", "application/x-www-form-urlencoded"),
      },
      {
        name: "multipart",
        make: () => {
          const form = new FormData()
          form.set("username", "inline")
          return request(form)
        },
      },
      {
        name: "malformed JSON",
        make: () => request("{", "application/json"),
      },
      {
        name: "text",
        make: () => request(JSON.stringify({ username: "inline" }), "text/plain"),
      },
      {
        name: "empty",
        make: () => request(undefined),
      },
      {
        name: "repeated field",
        make: () => request("username=inline&username=other", "application/x-www-form-urlencoded"),
      },
    ] as const

    try {
      for (const testCase of cases) {
        const legacyResponse = await legacy.handle(testCase.make())
        const replacementResponse = await kernel.handler(testCase.make())

        expect(
          {
            status: replacementResponse.status,
            contentType: replacementResponse.headers.get("content-type")?.split(";", 1)[0],
            body: await replacementResponse.text(),
          },
          testCase.name,
        ).toEqual({
          status: legacyResponse.status,
          contentType: legacyResponse.headers.get("content-type")?.split(";", 1)[0],
          body: await legacyResponse.text(),
        })
      }
      expect(replacementCalls).toBe(legacyCalls)
    } finally {
      await kernel.dispose()
    }
  })

  it("rejects invalid input before authentication or stateful work", async () => {
    let authenticationCalls = 0
    const operationCalls: Array<V1IdentitySpacesOperation> = []
    const kernel = makeKernel({
      operations: makeOperations({}, operationCalls),
      sessionAuthentication: {
        authenticate: () => {
          authenticationCalls += 1
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/getUser", {
          method: "POST",
          headers: {
            authorization: "Bearer 42:token",
            "content-type": "application/json",
          },
          body: "{}",
        }),
      )
      expect(response.status).toBe(400)
      expect(response.headers.get("content-type")).toContain("application/json")
      expect(response.headers.get("x-request-id")).toBeTruthy()
      expect(await response.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      })

      const malformed = await kernel.handler(
        new Request("http://inline.test/v1/getUser", {
          method: "POST",
          headers: {
            authorization: "Bearer 42:token",
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformed.status).toBe(500)
      expect(await malformed.json()).toEqual({
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      })
      expect(authenticationCalls).toBe(0)
      expect(operationCalls).toEqual([])

      const unsupported = await kernel.handler(
        new Request("http://inline.test/v1/getUser", {
          method: "PUT",
          headers: {
            authorization: "Bearer 42:token",
          },
        }),
      )
      expect(unsupported.status).toBe(404)
      expect(authenticationCalls).toBe(0)
      expect(operationCalls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("keeps authentication and operation defects private and reports each once", async () => {
    const reports: Array<unknown> = []
    const privateOperationCause = new Error("private database detail")
    const kernel = makeKernel({
      errorReporter: {
        report: (report) =>
          Effect.sync(() => {
            reports.push(report)
          }),
      },
      operations: makeOperations({
        getMe: () =>
          Effect.fail(
            new V1IdentitySpacesOperationFailure({
              operation: "v1.getMe",
              cause: privateOperationCause,
              publicError: new V1IdentitySpacesPublicError({
                error: "INTERNAL",
                errorCode: 500,
                description: "Internal server error happened",
              }),
            }),
          ),
      }),
      sessionAuthentication: {
        authenticate: (token) => {
          if (token === "42:revoked") {
            return Effect.fail(
              new SessionAuthenticationRejected({
                error: "SESSION_REVOKED",
                errorCode: 401,
                description: "Session revoked",
                connectionReason: ConnectionError_Reason.SESSION_REVOKED,
              }),
            )
          }
          if (token === "42:defect") {
            return Effect.fail(
              new SessionAuthenticationFailure({
                cause: new Error("private auth detail"),
              }),
            )
          }
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })
    const request = (token?: string) =>
      new Request("http://inline.test/v1/getMe", {
        headers: token === undefined ? undefined : { authorization: `Bearer ${token}` },
      })

    try {
      const missing = await kernel.handler(request())
      expect(missing.status).toBe(401)
      expect(await missing.json()).toMatchObject({
        error: "UNAUTHORIZED",
      })

      const revoked = await kernel.handler(request("42:revoked"))
      expect(revoked.status).toBe(401)
      expect(await revoked.json()).toMatchObject({
        error: "SESSION_REVOKED",
      })

      const authDefect = await kernel.handler(request("42:defect"))
      expect(authDefect.status).toBe(500)
      expect(await authDefect.text()).not.toContain("private auth detail")

      const operationDefect = await kernel.handler(request("42:valid"))
      expect(operationDefect.status).toBe(500)
      const operationDefectBody = await operationDefect.text()
      expect(JSON.parse(operationDefectBody)).toEqual({
        ok: false,
        error: "INTERNAL",
        errorCode: 500,
        description: "Internal server error happened",
      })
      expect(operationDefectBody).not.toContain("private database detail")
      expect(reports).toHaveLength(2)
    } finally {
      await kernel.dispose()
    }
  })

  it("serves a complete schema-backed OpenAPI fragment", async () => {
    const kernel = makeKernel({
      operations: makeOperations(),
    })

    try {
      const response = await kernel.handler(new Request("http://inline.test/v1/reference/json"))
      expect(response.status).toBe(200)
      const spec = (await response.json()) as {
        readonly paths: Record<string, Record<string, unknown>>
      }

      for (const testCase of routeCases) {
        const responses = {
          "200": expect.any(Object),
          "400": expect.any(Object),
          "401": expect.any(Object),
          "403": expect.any(Object),
          "420": expect.any(Object),
          "500": expect.any(Object),
        }
        expect(spec.paths[`/v1/${testCase.method}`]).toMatchObject({
          get: {
            parameters: expect.arrayContaining([
              expect.objectContaining({
                in: "header",
                name: "authorization",
                required: true,
              }),
            ]),
            responses,
          },
          post: {
            parameters: expect.arrayContaining([
              expect.objectContaining({
                in: "header",
                name: "authorization",
                required: true,
              }),
            ]),
            requestBody: {
              content: {
                "application/json": expect.any(Object),
                "application/x-www-form-urlencoded": expect.any(Object),
                "multipart/form-data": expect.any(Object),
              },
            },
            responses,
          },
        })
        expect(spec.paths[`/v1/{token}/${testCase.method}`]).toMatchObject({
          get: {
            parameters: expect.arrayContaining([
              expect.objectContaining({
                in: "path",
                name: "token",
                required: true,
              }),
            ]),
            responses,
          },
        })
      }
    } finally {
      await kernel.dispose()
    }
  })
})

const unused = (operation: string): never => {
  throw new Error(`Unexpected legacy operation: ${operation}`)
}

const makeLegacyOperations = (
  overrides: Partial<LegacyV1IdentitySpacesOperations> = {},
): LegacyV1IdentitySpacesOperations => ({
  checkUsername: async () => unused("checkUsername"),
  getMe: async () => unused("getMe"),
  getUser: async () => unused("getUser"),
  searchContacts: async () => unused("searchContacts"),
  updateProfile: async () => unused("updateProfile"),
  updateProfilePhoto: async () => unused("updateProfilePhoto"),
  updateStatus: async () => unused("updateStatus"),
  createSpace: async () => unused("createSpace"),
  deleteSpace: async () => unused("deleteSpace"),
  getSpaces: async () => unused("getSpaces"),
  getSpace: async () => unused("getSpace"),
  getInviteCodes: async () => unused("getInviteCodes"),
  addMember: async () => unused("addMember"),
  leaveSpace: async () => unused("leaveSpace"),
  getSpaceMembers: async () => unused("getSpaceMembers"),
  savePushNotification: async () => unused("savePushNotification"),
  ...overrides,
})

describe("slice 4 compatibility adapter", () => {
  it("passes decoded input and explicit identity context to the retained method", async () => {
    let received: unknown
    const adapter = makeV1IdentitySpacesOperations(
      makeLegacyOperations({
        searchContacts: async (input, context) => {
          received = { input, context }
          return fixtures.searchContacts
        },
      }),
    )

    await Effect.runPromise(
      adapter.searchContacts(
        { q: "inline", limit: 5 },
        {
          currentUserId: 42,
          currentSessionId: 7,
          ip: "203.0.113.8",
        },
      ),
    )

    expect(received).toEqual({
      input: { q: "inline", limit: 5 },
      context: {
        currentUserId: 42,
        currentSessionId: 7,
        ip: "203.0.113.8",
      },
    })
  })

  it("keeps expected Inline errors typed and preserves private 500 causes", async () => {
    const expected = makeV1IdentitySpacesOperations(
      makeLegacyOperations({
        addMember: async () => {
          throw new InlineError(InlineError.ApiError.SPACE_ADMIN_REQUIRED)
        },
      }),
    )
    const publicError = await Effect.runPromise(
      Effect.flip(
        expected.addMember(
          { spaceId: 9, userId: 43 },
          {
            currentUserId: 42,
            currentSessionId: 7,
            ip: undefined,
          },
        ),
      ),
    )
    expect(publicError).toMatchObject({
      _tag: "V1IdentitySpacesPublicError",
      error: "SPACE_ADMIN_REQUIRED",
      errorCode: 400,
    })

    const privateCause = new Error("database unavailable")
    const unexpected = makeV1IdentitySpacesOperations(
      makeLegacyOperations({
        updateProfile: async () => {
          throw new InlineError(InlineError.ApiError.INTERNAL, { cause: privateCause })
        },
      }),
    )
    const failure = await Effect.runPromise(
      Effect.flip(
        unexpected.updateProfile(
          { firstName: "Mo" },
          {
            currentUserId: 42,
            currentSessionId: 7,
            ip: undefined,
          },
        ),
      ),
    )
    expect(failure).toMatchObject({
      _tag: "V1IdentitySpacesOperationFailure",
      cause: privateCause,
      publicError: {
        error: "INTERNAL",
        errorCode: 500,
      },
    })
  })

  it("turns an invalid retained-method result into a typed adapter failure", async () => {
    const adapter = makeV1IdentitySpacesOperations(
      makeLegacyOperations({
        checkUsername: async () => ({
          available: "yes",
        }),
      }),
    )

    const failure = await Effect.runPromise(
      Effect.flip(
        adapter.checkUsername(
          { username: "inline" },
          {
            currentUserId: 42,
            currentSessionId: 7,
            ip: undefined,
          },
        ),
      ),
    )

    expect(failure).toMatchObject({
      _tag: "V1IdentitySpacesOperationFailure",
      operation: "v1.checkUsername.response",
      cause: {
        _tag: "V1IdentitySpacesResponseContractFailure",
        operation: "v1.checkUsername.response",
      },
    })
  })
})
