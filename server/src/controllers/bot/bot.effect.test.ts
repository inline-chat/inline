import { describe, expect, it } from "@effect/vitest"
import { readFileSync } from "node:fs"
import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
} from "effect"
import {
  HttpRouter,
  HttpServer,
} from "effect/unstable/http"
import { OpenApi } from "effect/unstable/httpapi"
import type {
  BotMessage,
  BotMethodName,
  GetChatHistoryParams,
  GetChatParams,
  SendMessageParams,
  SendReactionParams,
  SetMyCommandsParams,
} from "@inline-chat/bot-api-types"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "../../core/errors/errorReporter"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "../../core/http/application"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
} from "../../core/http/openApi"
import {
  assertValidOpenApiDocument,
} from "../../core/http/openApiValidation"
import { HttpRequestContext } from "../../core/http/requestContext"
import { RequestId } from "../../core/helpers/requestId"
import {
  SessionAuthentication,
  SessionAuthenticationFailure,
  SessionAuthenticationRejected,
  makeSessionIdentity,
  type SessionAuthenticationShape,
} from "../plugins.effect"
import {
  BotAuthorization,
  BotAuthorizationRejected,
  type BotAuthorizationShape,
} from "./auth.effect"
import {
  BotApiGroup,
  makeBotRouteGroup,
} from "./bot.effect"
import {
  BotOperationFailure,
  BotOperations,
  BotPublicError,
  type BotOperationsShape,
} from "./operations.effect"

const botUser = {
  id: 42,
  is_bot: true,
  username: "effect_bot",
  first_name: "Effect",
} as const

const botChat = {
  chat_id: 99,
  title: "Effect chat",
} as const

const botMessage: BotMessage = {
  message_id: 101,
  chat_id: botChat.chat_id,
  chat: botChat,
  peer: { user_id: 7 },
  from_id: botUser.id,
  from: botUser,
  date: 1_700_000_000,
  text: "hello",
  entities: [
    {
      type: "bold",
      offset: 0,
      length: 5,
    },
  ],
}

const unused = (operation: BotMethodName) =>
  Effect.die(
    new Error(`Unexpected Bot operation: ${operation}`),
  )

const makeOperations = (
  overrides: Partial<BotOperationsShape> = {},
): BotOperationsShape => ({
  getMe: () => unused("getMe"),
  sendMessage: () => unused("sendMessage"),
  getChat: () => unused("getChat"),
  getChatHistory: () => unused("getChatHistory"),
  editMessageText: () => unused("editMessageText"),
  deleteMessage: () => unused("deleteMessage"),
  sendReaction: () => unused("sendReaction"),
  getMyCommands: () => unused("getMyCommands"),
  setMyCommands: () => unused("setMyCommands"),
  deleteMyCommands: () => unused("deleteMyCommands"),
  ...overrides,
})

const defaultAuthorization: BotAuthorizationShape = {
  requireBot: () => Effect.void,
}

const defaultAuthentication: SessionAuthenticationShape = {
  authenticate: () =>
    Effect.succeed(makeSessionIdentity(botUser.id, 7)),
}

const makeKernel = ({
  authorization = defaultAuthorization,
  authentication = defaultAuthentication,
  operations,
  reporter = {
    report: () => Effect.void,
  },
}: {
  readonly authorization?: BotAuthorizationShape | undefined
  readonly authentication?: SessionAuthenticationShape | undefined
  readonly operations: BotOperationsShape
  readonly reporter?: ErrorReporterShape | undefined
}) => {
  const routeGroup = makeBotRouteGroup()
  const platformApi = makePlatformApiBase(
    "https://api.inline.chat",
  )
  const botApi = makeBotApiBase(
    "https://api.inline.chat",
  ).add(BotApiGroup)
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: Layer.empty,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: routeGroup.handlers,
    }),
    middleware: {
      isProduction: false,
    },
  }).pipe(
    Layer.provide(HttpServer.layerServices),
    Layer.provide(EffectErrorReporter.layer([])),
    Layer.provide(Layer.succeed(ErrorReporter, reporter)),
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(BotAuthorization, authorization),
        Layer.succeed(BotOperations, operations),
        Layer.succeed(
          SessionAuthentication,
          authentication,
        ),
      ),
    ),
  )
  const webHandler = HttpRouter.toWebHandler(application, {
    disableLogger: true,
  })
  const context = Context.make(HttpRequestContext, {
    clientIp: "unresolved-client",
    method: "GET",
    path: "/test",
    requestId: RequestId.make("bot-test"),
    startedAtMillis: 0,
  }).pipe(
    Context.add(BotAuthorization, authorization),
    Context.add(BotOperations, operations),
    Context.add(
      SessionAuthentication,
      authentication,
    ),
    Context.add(ErrorReporter, reporter),
  )

  return {
    dispose: webHandler.dispose,
    handler: (request: Request) =>
      webHandler.handler(request, context),
  }
}

const jsonRequest = (
  path: string,
  body: Record<string, unknown>,
  token = "42:HEADER",
) =>
  new Request(`http://inline.test${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  })

describe("Effect Bot routes", () => {
  it("serves all ten methods through both header and path-token forms", async () => {
    const calls: BotMethodName[] = []
    const invoked = <A>(
      operation: BotMethodName,
      result: A,
    ) =>
      Effect.sync(() => {
        calls.push(operation)
        return result
      })
    const operations = makeOperations({
      getMe: () =>
        invoked("getMe", { user: botUser }),
      sendMessage: () =>
        invoked("sendMessage", { message: botMessage }),
      getChat: () =>
        invoked("getChat", { chat: botChat }),
      getChatHistory: () =>
        invoked("getChatHistory", {
          messages: [botMessage],
        }),
      editMessageText: () =>
        invoked("editMessageText", {
          message: botMessage,
        }),
      deleteMessage: () =>
        invoked("deleteMessage", {}),
      sendReaction: () =>
        invoked("sendReaction", {}),
      getMyCommands: () =>
        invoked("getMyCommands", {
          commands: [
            {
              command: "start",
              description: "Start",
              sort_order: 1,
            },
          ],
        }),
      setMyCommands: () =>
        invoked("setMyCommands", {}),
      deleteMyCommands: () =>
        invoked("deleteMyCommands", {}),
    })
    const kernel = makeKernel({ operations })
    const methods = [
      {
        name: "getMe",
        method: "GET",
        input: undefined,
      },
      {
        name: "sendMessage",
        method: "POST",
        input: { user_id: 7, text: "hello" },
      },
      {
        name: "getChat",
        method: "GET",
        input: { user_id: "7" },
      },
      {
        name: "getChatHistory",
        method: "GET",
        input: { chat_id: "99", limit: "10" },
      },
      {
        name: "editMessageText",
        method: "POST",
        input: {
          chat_id: 99,
          message_id: 101,
          text: "edited",
        },
      },
      {
        name: "deleteMessage",
        method: "POST",
        input: { chat_id: 99, message_id: 101 },
      },
      {
        name: "sendReaction",
        method: "POST",
        input: {
          chat_id: 99,
          message_id: 101,
          emoji: "👍",
        },
      },
      {
        name: "getMyCommands",
        method: "GET",
        input: undefined,
      },
      {
        name: "setMyCommands",
        method: "POST",
        input: {
          commands: [
            {
              command: "start",
              description: "Start",
            },
          ],
        },
      },
      {
        name: "deleteMyCommands",
        method: "POST",
        input: {},
      },
    ] as const

    try {
      for (const authForm of ["header", "path"] as const) {
        for (const method of methods) {
          const prefix =
            authForm === "header"
              ? "/bot"
              : `/bot${encodeURIComponent("42:PATH")}`
          const search =
            method.method === "GET" &&
            method.input !== undefined
              ? `?${new URLSearchParams(method.input)}`
              : ""
          const request = new Request(
            `http://inline.test${prefix}/${method.name}${search}`,
            {
              method: method.method,
              headers:
                authForm === "header"
                  ? {
                      authorization: "Bearer 42:HEADER",
                      ...(method.method === "POST"
                        ? {
                            "content-type":
                              "application/json",
                          }
                        : {}),
                    }
                  : method.method === "POST"
                    ? {
                        "content-type":
                          "application/json",
                      }
                    : undefined,
              body:
                method.method === "POST"
                  ? JSON.stringify(method.input)
                  : undefined,
            },
          )
          const response = await kernel.handler(request)

          expect(response.status).toBe(200)
          expect(
            response.headers.get("content-type"),
          ).toContain("application/json")
          expect(await response.json()).toMatchObject({
            ok: true,
          })
        }
      }

      expect(calls).toHaveLength(20)
      for (const method of methods) {
        expect(
          calls.filter((call) => call === method.name),
        ).toHaveLength(2)
      }
    } finally {
      await kernel.dispose()
    }
  })

  it("validates Bot responses after JSON omits nested undefined properties", async () => {
    const kernel = makeKernel({
      operations: makeOperations({
        getChat: () =>
          Effect.succeed({
            chat: {
              chat_id: 99,
              title: undefined,
              space_id: undefined,
              emoji: undefined,
            },
          }),
      }),
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/bot/getChat?chat_id=99",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )

      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        ok: true,
        result: {
          chat: {
            chat_id: 99,
          },
        },
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("accepts POST query parameters and lets JSON body values win", async () => {
    let sendInput: SendMessageParams | undefined
    let reactionInput: SendReactionParams | undefined
    let commandsInput: SetMyCommandsParams | undefined
    const operations = makeOperations({
      sendMessage: (input) => {
        sendInput = input
        return Effect.succeed({
          message: {
            ...botMessage,
            peer: { thread_id: botChat.chat_id },
          },
        })
      },
      sendReaction: (input) => {
        reactionInput = input
        return Effect.succeed({})
      },
      setMyCommands: (input) => {
        commandsInput = input
        return Effect.succeed({})
      },
    })
    const kernel = makeKernel({ operations })

    try {
      const sendResponse = await kernel.handler(
        jsonRequest(
          "/bot/sendMessage?user_id=7&text=from-query",
          {
            user_id: "8",
            reply_to_message_id: "101",
            text: "from-body",
          },
        ),
      )
      const reactionResponse = await kernel.handler(
        new Request(
          "http://inline.test/bot/sendReaction?chat_id=99&message_id=101&emoji=%F0%9F%94%A5",
          {
            method: "POST",
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const commandsResponse = await kernel.handler(
        jsonRequest("/bot/setMyCommands", {
          commands: [
            {
              command: " deploy ",
              description: " Deploy the latest build ",
              sort_order: "10",
            },
          ],
        }),
      )

      expect(sendResponse.status).toBe(200)
      expect(await sendResponse.json()).toMatchObject({
        result: {
          message: {
            peer: { thread_id: botChat.chat_id },
          },
        },
      })
      expect(sendInput).toMatchObject({
        user_id: 8,
        reply_to_message_id: 101,
        text: "from-body",
      })
      expect(reactionResponse.status).toBe(200)
      expect(reactionInput).toMatchObject({
        chat_id: 99,
        message_id: 101,
        emoji: "🔥",
      })
      expect(commandsResponse.status).toBe(200)
      expect(commandsInput).toEqual({
        commands: [
          {
            command: "deploy",
            description: "Deploy the latest build",
            sort_order: 10,
          },
        ],
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("prefers header authentication over a path token and decodes path tokens", async () => {
    const tokens: string[] = []
    const kernel = makeKernel({
      authentication: {
        authenticate: (token) =>
          Effect.sync(() => {
            tokens.push(token)
            return makeSessionIdentity(botUser.id, 7)
          }),
      },
      operations: makeOperations({
        getMe: () =>
          Effect.succeed({ user: botUser }),
      }),
    })

    try {
      const precedenceResponse = await kernel.handler(
        new Request(
          "http://inline.test/bot42%3APATH/getMe",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const encodedResponse = await kernel.handler(
        new Request(
          "http://inline.test/bot42%3AENCODED/getMe",
        ),
      )

      expect(precedenceResponse.status).toBe(200)
      expect(encodedResponse.status).toBe(200)
      expect(tokens).toEqual([
        "42:HEADER",
        "42:ENCODED",
      ])
    } finally {
      await kernel.dispose()
    }
  })

  it("rejects authentication and malformed bodies before invoking an operation", async () => {
    let calls = 0
    const operations = makeOperations({
      sendMessage: () =>
        Effect.sync(() => {
          calls += 1
          return { message: botMessage }
        }),
    })

    const missingKernel = makeKernel({ operations })
    const rejectedKernel = makeKernel({
      operations,
      authentication: {
        authenticate: () =>
          Effect.fail(
            new SessionAuthenticationRejected({
              error: "UNAUTHORIZED",
              errorCode: 401,
              description: "Unauthorized",
              connectionReason: 1,
            }),
          ),
      },
    })
    const nonBotKernel = makeKernel({
      operations,
      authorization: {
        requireBot: () =>
          Effect.fail(
            new BotAuthorizationRejected({
              error: "UNAUTHORIZED",
              errorCode: 401,
              description: "Unauthorized",
            }),
          ),
      },
    })
    const malformedKernel = makeKernel({ operations })

    try {
      const missing = await missingKernel.handler(
        new Request(
          "http://inline.test/bot/sendMessage",
          { method: "POST" },
        ),
      )
      const rejected = await rejectedKernel.handler(
        jsonRequest("/bot/sendMessage", {
          user_id: 7,
          text: "no",
        }),
      )
      const nonBot = await nonBotKernel.handler(
        jsonRequest("/bot/sendMessage", {
          user_id: 7,
          text: "no",
        }),
      )
      const malformed = await malformedKernel.handler(
        new Request(
          "http://inline.test/bot/sendMessage",
          {
            method: "POST",
            headers: {
              authorization: "Bearer 42:HEADER",
              "content-type": "application/json",
            },
            body: "{",
          },
        ),
      )
      const malformedWithoutAuthentication =
        await malformedKernel.handler(
          new Request(
            "http://inline.test/bot/sendMessage",
            {
              method: "POST",
              headers: {
                "content-type": "application/json",
              },
              body: "{",
            },
          ),
        )
      const schemaInvalid = await malformedKernel.handler(
        jsonRequest("/bot/sendMessage", {
          user_id: 7,
          text: 42,
        }),
      )
      const negativeEntityRange =
        await malformedKernel.handler(
          jsonRequest("/bot/sendMessage", {
            user_id: 7,
            text: "invalid entity",
            entities: [
              {
                type: "bold",
                offset: -1,
                length: 7,
              },
            ],
          }),
        )

      for (const response of [
        missing,
        rejected,
        nonBot,
      ]) {
        expect(response.status).toBe(401)
        expect(await response.json()).toMatchObject({
          ok: false,
          error_code: 401,
        })
      }
      expect(malformed.status).toBe(400)
      expect(await malformed.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
        description: "Validation error",
      })
      expect(malformedWithoutAuthentication.status).toBe(
        400,
      )
      expect(
        await malformedWithoutAuthentication.json(),
      ).toMatchObject({
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
      })
      expect(schemaInvalid.status).toBe(400)
      expect(await schemaInvalid.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
        description: "Validation error",
      })
      expect(negativeEntityRange.status).toBe(400)
      expect(await negativeEntityRange.json()).toMatchObject({
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
      })
      expect(calls).toBe(0)
    } finally {
      await Promise.all([
        missingKernel.dispose(),
        rejectedKernel.dispose(),
        nonBotKernel.dispose(),
        malformedKernel.dispose(),
      ])
    }
  })

  it("returns authenticated Bot envelopes for unknown paths and unsupported method variants", async () => {
    const kernel = makeKernel({
      operations: makeOperations(),
    })

    try {
      const unknownHeader = await kernel.handler(
        new Request(
          "http://inline.test/bot/notAMethod",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const unsupportedPost = await kernel.handler(
        jsonRequest("/bot/getMe", {}),
      )
      const unknownPathToken = await kernel.handler(
        new Request(
          "http://inline.test/bot42%3APATH/notAMethod",
        ),
      )
      const unauthenticated = await kernel.handler(
        new Request(
          "http://inline.test/bot/notAMethod",
        ),
      )

      for (const response of [
        unknownHeader,
        unsupportedPost,
        unknownPathToken,
      ]) {
        expect(response.status).toBe(404)
        expect(await response.json()).toEqual({
          ok: false,
          error: "METHOD_NOT_FOUND",
          error_code: 404,
          description: "Method not found",
        })
      }
      expect(unauthenticated.status).toBe(401)
      expect(await unauthenticated.json()).toMatchObject({
        ok: false,
        error: "UNAUTHORIZED",
        error_code: 401,
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("maps expected errors and reports unexpected operation failures once without leaking causes", async () => {
    const reports: unknown[] = []
    const reporter: ErrorReporterShape = {
      report: (report) =>
        Effect.sync(() => {
          reports.push(report)
        }),
    }
    const expectedKernel = makeKernel({
      operations: makeOperations({
        getChat: () =>
          Effect.fail(
            new BotPublicError({
              error: "CHAT_ID_INVALID",
              errorCode: 400,
              description: "The chat id is invalid",
            }),
          ),
      }),
      reporter,
    })
    const failureKernel = makeKernel({
      operations: makeOperations({
        getChat: () =>
          Effect.fail(
            new BotOperationFailure({
              operation: "getChat",
              cause: new Error(
                "private database host and token",
              ),
            }),
          ),
      }),
      reporter,
    })

    try {
      const expected = await expectedKernel.handler(
        new Request(
          "http://inline.test/bot/getChat?chat_id=99",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const failure = await failureKernel.handler(
        new Request(
          "http://inline.test/bot/getChat?chat_id=99",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )

      expect(expected.status).toBe(400)
      expect(await expected.json()).toEqual({
        ok: false,
        error: "CHAT_ID_INVALID",
        error_code: 400,
        description: "The chat id is invalid",
      })
      expect(failure.status).toBe(500)
      const failureText = await failure.text()
      expect(JSON.parse(failureText)).toEqual({
        ok: false,
        error: "INTERNAL",
        error_code: 500,
        description: "Internal server error happened",
      })
      expect(failureText).not.toContain(
        "private database host",
      )
      expect(reports).toHaveLength(1)
    } finally {
      await Promise.all([
        expectedKernel.dispose(),
        failureKernel.dispose(),
      ])
    }
  })

  it("enforces the declared success schema before emitting a response", async () => {
    let reports = 0
    const kernel = makeKernel({
      operations: makeOperations({
        getMe: () =>
          Effect.succeed({
            user: {
              ...botUser,
              id: -1,
            },
          }),
      }),
      reporter: {
        report: () =>
          Effect.sync(() => {
            reports += 1
          }),
      },
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/bot/getMe",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )

      expect(response.status).toBe(500)
      expect(await response.json()).toEqual({
        ok: false,
        error: "INTERNAL",
        error_code: 500,
        description: "Internal server error happened",
      })
      expect(reports).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("reports authentication dependency failures once with the Bot envelope", async () => {
    let reports = 0
    const kernel = makeKernel({
      authentication: {
        authenticate: () =>
          Effect.fail(
            new SessionAuthenticationFailure({
              cause: new Error("private session store"),
            }),
          ),
      },
      operations: makeOperations({
        getMe: () =>
          Effect.succeed({ user: botUser }),
      }),
      reporter: {
        report: () =>
          Effect.sync(() => {
            reports += 1
          }),
      },
    })

    try {
      const response = await kernel.handler(
        new Request(
          "http://inline.test/bot/getMe",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const text = await response.text()

      expect(response.status).toBe(500)
      expect(JSON.parse(text)).toEqual({
        ok: false,
        error: "SERVER_ERROR",
        error_code: 500,
        description: "Server error",
      })
      expect(text).not.toContain("private session store")
      expect(reports).toBe(1)
    } finally {
      await kernel.dispose()
    }
  })

  it("generates a complete canonical Bot OpenAPI document from the executable group", () => {
    const api = makeBotApiBase(
      "https://api.inline.chat",
    ).add(BotApiGroup)
    const spec = OpenApi.fromApi(api)

    expect(() =>
      assertValidOpenApiDocument(spec),
    ).not.toThrow()
    expect(Object.keys(spec.paths)).toHaveLength(20)

    const expectedMethods = [
      "getMe",
      "sendMessage",
      "getChat",
      "getChatHistory",
      "editMessageText",
      "deleteMessage",
      "sendReaction",
      "getMyCommands",
      "setMyCommands",
      "deleteMyCommands",
    ]
    for (const method of expectedMethods) {
      expect(spec.paths[`/bot/${method}`]).toBeDefined()
      expect(
        spec.paths[`/bot{token}/${method}`],
      ).toBeDefined()
    }

    const headerGetMe =
      spec.paths["/bot/getMe"]?.["get"]
    const pathGetMe =
      spec.paths["/bot{token}/getMe"]?.["get"]
    const sendMessage =
      spec.paths["/bot/sendMessage"]?.["post"]
    const pathSendMessage =
      spec.paths["/bot{token}/sendMessage"]?.["post"]
    expect(headerGetMe).toBeDefined()
    expect(pathGetMe).toBeDefined()
    expect(sendMessage).toBeDefined()
    expect(pathSendMessage).toBeDefined()

    const headerAuthorization =
      headerGetMe?.parameters?.find(
        (parameter) =>
          "name" in parameter &&
          parameter.name === "authorization",
      )
    const pathAuthorization =
      pathGetMe?.parameters?.find(
        (parameter) =>
          "name" in parameter &&
          parameter.name === "authorization",
      )
    const pathToken =
      pathGetMe?.parameters?.find(
        (parameter) =>
          "name" in parameter &&
          parameter.name === "token",
      )
    expect(
      headerAuthorization &&
        "required" in headerAuthorization
        ? headerAuthorization.required
        : undefined,
    ).toBe(true)
    expect(
      pathAuthorization &&
        "required" in pathAuthorization
        ? pathAuthorization.required
        : undefined,
    ).not.toBe(true)
    expect(pathToken).toMatchObject({
      required: true,
      description:
        "Required bot token included in the URL path.",
    })
    const sendMessageAuthorization =
      sendMessage?.parameters?.find(
        (parameter) =>
          "name" in parameter &&
          parameter.name === "authorization",
      )
    const pathSendMessageAuthorization =
      pathSendMessage?.parameters?.find(
        (parameter) =>
          "name" in parameter &&
          parameter.name === "authorization",
      )
    expect(
      sendMessageAuthorization &&
        "required" in sendMessageAuthorization
        ? sendMessageAuthorization.required
        : undefined,
    ).toBe(true)
    expect(
      pathSendMessageAuthorization &&
        "required" in pathSendMessageAuthorization
        ? pathSendMessageAuthorization.required
        : undefined,
    ).not.toBe(true)
    expect(sendMessageAuthorization).toMatchObject({
      description:
        "Required bot token using the Bearer scheme.",
    })
    expect(pathSendMessageAuthorization).toMatchObject({
      description:
        "Optional bot token using the Bearer scheme. When supplied, it takes precedence over the token in the URL.",
    })
    expect(sendMessage?.requestBody).toMatchObject({
      required: false,
    })
    expect(pathSendMessage?.requestBody).toMatchObject({
      required: false,
    })
    expect(sendMessage?.responses).toHaveProperty("400")
    expect(sendMessage?.responses).toHaveProperty("401")
    expect(sendMessage?.responses).toHaveProperty("403")
    expect(sendMessage?.responses).toHaveProperty("404")
    expect(sendMessage?.responses).not.toHaveProperty("420")
    expect(sendMessage?.responses).toHaveProperty("500")

    const getChatHistory =
      spec.paths["/bot/getChatHistory"]?.["get"]
    expect(getChatHistory?.parameters).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "user_id",
          description:
            "Target a private conversation with this user. Supply exactly one of user_id or chat_id.",
          schema: {
            $ref: "#/components/schemas/UserIdString",
          },
        }),
        expect.objectContaining({
          name: "chat_id",
          description:
            "Target this chat. Supply exactly one of chat_id or user_id.",
          schema: {
            $ref: "#/components/schemas/ChatIdString",
          },
        }),
        expect.objectContaining({
          name: "limit",
          description:
            "Maximum number of messages to return.",
          schema: {
            $ref: "#/components/schemas/SafeIntegerString",
          },
        }),
        expect.objectContaining({
          name: "offset_message_id",
          description:
            "Pagination cursor. When supplied, return messages older than this message.",
          schema: {
            $ref: "#/components/schemas/MessageIdString",
          },
        }),
      ]),
    )
    expect(
      spec.components.schemas["UserIdString"],
    ).toMatchObject({
      type: "string",
      allOf: [
        expect.objectContaining({
          pattern: "^[1-9][0-9]*$",
        }),
      ],
    })
    expect(
      spec.components.schemas["EditMessageTextInput"],
    ).toMatchObject({
      description:
        "Parameters for editing a text message. Exactly one target field is required.",
      properties: {
        message_id: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/MessageId",
            },
            {
              description:
                "Message to edit in the target chat.",
            },
          ]),
        },
        chat_id: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/ChatId",
            },
            {
              description:
                "Target this chat. Supply exactly one of chat_id or user_id.",
            },
          ]),
        },
        user_id: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/UserId",
            },
            {
              description:
                "Target a private conversation with this user. Supply exactly one of user_id or chat_id.",
            },
          ]),
        },
      },
    })
    expect(sendMessage?.description).toContain(
      "Supply exactly one of user_id or chat_id.",
    )
    expect(
      spec.components.schemas["BotMessageSuccess"],
    ).toMatchObject({
      examples: [
        {
          ok: true,
          result: {
            message: {
              message_id: 1_808,
              text: "Deployment finished successfully.",
              chat: {
                last_message_id: 1_808,
                last_message: {
                  message_id: 1_808,
                  text: "Deployment finished successfully.",
                },
              },
            },
          },
        },
      ],
    })
    for (const schemaName of [
      "BotGetMeSuccess",
      "BotGetChatSuccess",
      "BotGetChatHistorySuccess",
      "BotMessageSuccess",
      "BotGetMyCommandsSuccess",
      "BotEmptySuccess",
    ]) {
      expect(
        spec.components.schemas[schemaName],
      ).toMatchObject({
        examples: [expect.any(Object)],
      })
    }
    expect(
      spec.components.schemas["BotBadRequestError"],
    ).toMatchObject({
      description:
        "The request parameters are missing or invalid.",
      examples: [
        {
          ok: false,
          error: "CHAT_ID_INVALID",
          error_code: 400,
          description: "The chat id is invalid",
        },
      ],
      properties: {
        error_code: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/HttpStatusCode",
            },
          ]),
        },
      },
    })
    expect(
      Object.keys(spec.components.schemas),
    ).toEqual(
      expect.arrayContaining([
        "BotBadRequestError",
        "BotUnauthorizedError",
        "BotForbiddenError",
        "BotNotFoundError",
        "BotInternalServerError",
      ]),
    )
    expect(
      Object.keys(spec.components.schemas),
    ).not.toEqual(
      expect.arrayContaining([
        "BotApiError1",
        "BotApiError2",
        "BotApiError3",
        "BotApiError4",
      ]),
    )
    expect(
      spec.components.schemas["BotCommand"],
    ).toMatchObject({
      properties: {
        command: {
          allOf: expect.arrayContaining([
            { minLength: 1 },
            { maxLength: 32 },
            { pattern: "^[a-z0-9_]+$" },
          ]),
        },
        description: {
          allOf: expect.arrayContaining([
            { minLength: 1 },
            { maxLength: 256 },
          ]),
        },
      },
    })
    expect(
      spec.components.schemas["SetMyCommandsInput"],
    ).toMatchObject({
      properties: {
        commands: {
          maxItems: 100,
        },
      },
    })
    expect(
      spec.components.schemas["SetMyCommandsInput"],
    ).not.toMatchObject({
      properties: {
        commands: {
          allOf: expect.arrayContaining([
            { maxItems: 100 },
          ]),
        },
      },
    })
    expect(
      spec.components.schemas["BotMessageEntityInput"],
    ).toMatchObject({
      properties: {
        offset: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/WireNonNegativeInteger",
            },
          ]),
        },
        length: {
          allOf: expect.arrayContaining([
            {
              $ref: "#/components/schemas/WireNonNegativeInteger",
            },
          ]),
        },
      },
    })
    expect(
      spec.components.schemas["BotEmptyResult"],
    ).toMatchObject({
      type: "object",
      additionalProperties: false,
    })
    expect(
      spec.components.schemas["BotEmptyResult"],
    ).not.toHaveProperty("anyOf")
    expect(
      spec.components.schemas["BotUser"],
    ).toMatchObject({
      description:
        "Basic information about an Inline user or bot.",
      properties: {
        username: {
          allOf: [
            {
              description:
                "Public username, without the leading @.",
            },
          ],
        },
      },
    })

    const text = JSON.stringify(spec)
    expect(text).toContain("chat_id")
    expect(text).toContain("user_id")
    expect(text).toContain("parse_markdown")
    expect(text).toContain("error_code")
    expect(text).toContain("BotMessageEntityOutput")
    expect(text).not.toContain("peer_thread_id")
    expect(text).not.toContain("peer_user_id")
    expect(text).not.toContain("parseMarkdown")
    expect(text).not.toContain("thread_id")
    expect(text).not.toContain("BotInputId")
    expect(text).not.toContain("MessageIdInput")
    expect(text).not.toContain("ChatIdInput")
    expect(text).not.toContain("UserIdInput")
    expect(JSON.stringify(getChatHistory)).not.toContain(
      "(?:[Ee]",
    )
  })

  it("matches the checked-in legacy oracle's Bot path and method coverage", () => {
    const legacy = JSON.parse(
      readFileSync(
        new URL(
          "../../__tests__/contracts/fixtures/bot-openapi.json",
          import.meta.url,
        ),
        "utf8",
      ),
    ) as {
      readonly paths: Readonly<
        Record<string, Readonly<Record<string, unknown>>>
      >
    }
    const effect = OpenApi.fromApi(
      makeBotApiBase("https://api.inline.chat").add(
        BotApiGroup,
      ),
    )
    const normalizePath = (path: string) =>
      path.replace("{token}", ":token")
    const methodsByPath = (
      paths: Readonly<
        Record<string, Readonly<Record<string, unknown>>>
      >,
    ) =>
      Object.fromEntries(
        Object.entries(paths)
          .filter(([path]) => path.startsWith("/bot"))
          .map(([path, methods]) => [
            normalizePath(path),
            Object.keys(methods).sort(),
          ] as const)
          .sort(([left], [right]) =>
            left.localeCompare(right),
          ),
      )

    expect(methodsByPath(effect.paths)).toEqual(
      methodsByPath(legacy.paths),
    )
  })

  it("passes decoded GET query values to the operation boundary", async () => {
    let chatInput: GetChatParams | undefined
    let historyInput: GetChatHistoryParams | undefined
    const kernel = makeKernel({
      operations: makeOperations({
        getChat: (value) => {
          chatInput = value
          return Effect.succeed({ chat: botChat })
        },
        getChatHistory: (value) => {
          historyInput = value
          return Effect.succeed({ messages: [] })
        },
      }),
    })

    try {
      const chatResponse = await kernel.handler(
        new Request(
          "http://inline.test/bot/getChat?user_id=7",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )
      const historyResponse = await kernel.handler(
        new Request(
          "http://inline.test/bot/getChatHistory?chat_id=99&limit=10&offset_message_id=101",
          {
            headers: {
              authorization: "Bearer 42:HEADER",
            },
          },
        ),
      )

      expect(chatResponse.status).toBe(200)
      expect(historyResponse.status).toBe(200)
      expect(chatInput).toEqual({ user_id: 7 })
      expect(historyInput).toEqual({
        chat_id: 99,
        limit: 10,
        offset_message_id: 101,
      })
    } finally {
      await kernel.dispose()
    }
  })
})
