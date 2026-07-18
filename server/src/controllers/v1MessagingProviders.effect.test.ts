import { describe, expect, it } from "@effect/vitest"
import * as BunFileSystem from "@effect/platform-bun/BunFileSystem"
import * as BunPath from "@effect/platform-bun/BunPath"
import { Context, Effect, ErrorReporter as EffectErrorReporter, Layer, Schema } from "effect"
import { Elysia, t } from "elysia"
import { HttpRouter, HttpServer, HttpServerRequest } from "effect/unstable/http"
import { ErrorReporter, type ErrorReporterShape } from "../core/errors/errorReporter"
import { defineExecutableHttpApi, makeHttpApplication } from "../core/http/application"
import { defineOpenApiDocument, makeBotApiBase, makePlatformApiBase } from "../core/http/openApi"
import { HttpRequestContext } from "../core/http/requestContext"
import { RequestId } from "../core/helpers/requestId"
import {
  SessionAuthentication,
  makeSessionIdentity,
  type SessionAuthenticationShape,
} from "./plugins.effect"
import {
  V1MessagingProvidersApiGroup,
  type V1MessagingProvidersOperation,
} from "./v1MessagingProvidersContracts.effect"
import { makeV1MessagingProvidersRouteGroup } from "./v1MessagingProviders.effect"
import {
  V1MessagingProvidersOperationFailure,
  V1MessagingProvidersPublicError,
} from "./v1MessagingProvidersErrors.effect"
import {
  AddReactionResult,
  MessageInfo,
} from "./v1MessagingSchemas.effect"
import {
  ChatInfo,
  DialogInfo,
} from "./v1IdentitySpacesSchemas.effect"
import {
  UserInfo,
} from "../modules/auth/identitySchemas.effect"
import {
  V1MessagingOperations,
  type V1MessagingOperationsShape,
} from "./v1MessagingOperations.effect"
import { V1ProviderOperations, type V1ProviderOperationsShape } from "./v1ProviderOperations.effect"
import {
  LinearTeamId,
  NotionDatabaseId,
} from "./v1ProviderSchemas.effect"
import {
  makeV1UploadAdmission,
  V1UploadAdmission,
} from "./v1UploadAdmission.effect"
import { V1UploadOperations, type V1UploadOperationsShape } from "./v1UploadOperations.effect"
import {
  defaultV1UploadLimits,
  parseV1UploadRequest,
} from "./v1UploadRequest.effect"

const decode = <A>(schema: Schema.Decoder<A>, input: unknown): A =>
  Schema.decodeUnknownSync(schema)(input)

const bunFileContext =
  Effect.runSync(
    Effect.scoped(
      Layer.build(
        Layer.merge(
          BunFileSystem.layer,
          BunPath.layer,
        ),
      ),
    ),
  )

interface MultipartTestPart {
  readonly name: string
  readonly value: string
  readonly filename?: string
  readonly contentType?: string
}

const makeMultipartRequest = (
  parts: ReadonlyArray<MultipartTestPart>,
  headers: HeadersInit = {},
) => {
  const boundary = "inline-effect-test-boundary"
  const body = parts
    .map((part) => {
      const filename =
        part.filename === undefined ? "" : `; filename="${part.filename}"`
      const contentType =
        part.contentType === undefined
          ? ""
          : `Content-Type: ${part.contentType}\r\n`
      return [
        `--${boundary}\r\n`,
        `Content-Disposition: form-data; name="${part.name}"${filename}\r\n`,
        contentType,
        "\r\n",
        part.value,
        "\r\n",
      ].join("")
    })
    .join("")

  return new Request("http://inline.test/v1/uploadFile", {
    method: "POST",
    headers: {
      "content-type": `multipart/form-data; boundary=${boundary}`,
      ...headers,
    },
    body: `${body}--${boundary}--\r\n`,
  })
}

const date = 1_700_000_000
const user = decode(UserInfo, {
  id: 42,
  firstName: "Mo",
  username: "mo",
  date,
})
const chat = decode(ChatInfo, {
  id: 8,
  type: "private",
  peer: { userId: 43 },
  date,
})
const threadChat = decode(ChatInfo, {
  id: 8,
  type: "thread",
  peer: { threadId: 8 },
  date,
  title: "General",
  spaceId: 9,
})
const dialog = decode(DialogInfo, {
  peerId: { userId: 43 },
  chatId: 8,
  unreadCount: 0,
})
const message = decode(MessageInfo, {
  id: 7,
  peerId: { userId: 43 },
  chatId: 8,
  fromId: 42,
  text: "hello",
  date,
})
const addReactionResult = decode(AddReactionResult, {
  reaction: {
    id: 1,
    messageId: 7,
    chatId: 8,
    userId: 42,
    emoji: "👍",
    date,
  },
})
const linearTeamId = decode(LinearTeamId, "team")
const notionDatabaseId = decode(NotionDatabaseId, "database")

const makeMessaging = (
  calls: Array<V1MessagingProvidersOperation>,
  overrides: Partial<V1MessagingOperationsShape> = {},
): V1MessagingOperationsShape => ({
  addReaction: () => {
    calls.push("addReaction")
    return Effect.succeed(addReactionResult)
  },
  createPrivateChat: () => {
    calls.push("createPrivateChat")
    return Effect.succeed({ chat, dialog, user })
  },
  createThread: () => {
    calls.push("createThread")
    return Effect.succeed({ chat: threadChat })
  },
  deleteMessage: () => {
    calls.push("deleteMessage")
    return Effect.void
  },
  getAlphaText: () => {
    calls.push("getAlphaText")
    return Effect.succeed("alpha")
  },
  getChatHistory: () => {
    calls.push("getChatHistory")
    return Effect.succeed({ messages: [message] })
  },
  getDialogs: () => {
    calls.push("getDialogs")
    return Effect.succeed({ dialogs: [dialog], chats: [chat], messages: [message], users: [user] })
  },
  getDraft: () => {
    calls.push("getDraft")
    return Effect.succeed({ draft: "draft" })
  },
  getPrivateChats: () => {
    calls.push("getPrivateChats")
    return Effect.succeed({ dialogs: [dialog], chats: [chat], messages: [message], peerUsers: [user] })
  },
  readMessages: () => {
    calls.push("readMessages")
    return Effect.succeed({})
  },
  sendComposeAction: () => {
    calls.push("sendComposeAction")
    return Effect.void
  },
  sendMessage: () => {
    calls.push("sendMessage")
    return Effect.succeed({
      message,
      updates: [{ updateMessageId: { messageId: 7, randomId: "123" } }],
    })
  },
  sendMessage20250509: () => {
    calls.push("sendMessage20250509")
    return Effect.succeed({})
  },
  updateDialog: () => {
    calls.push("updateDialog")
    return Effect.succeed({ dialog })
  },
  ...overrides,
})

const makeProviders = (
  calls: Array<V1MessagingProvidersOperation>,
  overrides: Partial<V1ProviderOperationsShape> = {},
): V1ProviderOperationsShape => ({
  createLinearIssue: () => {
    calls.push("createLinearIssue")
    return Effect.succeed({ link: "https://linear.app/issue/INLINE-1" })
  },
  createNotionTask: () => {
    calls.push("createNotionTask")
    return Effect.succeed({ url: "https://notion.so/task", taskTitle: "Task" })
  },
  deleteAttachment: () => {
    calls.push("deleteAttachment")
    return Effect.succeed({ success: true })
  },
  disconnectIntegration: () => {
    calls.push("disconnectIntegration")
    return Effect.succeed({ ok: true })
  },
  getIntegrations: () => {
    calls.push("getIntegrations")
    return Effect.succeed({
      hasLinearConnected: true,
      hasNotionConnected: true,
      hasIntegrationAccess: true,
    })
  },
  getLinearTeams: () => {
    calls.push("getLinearTeams")
    return Effect.succeed([{ id: linearTeamId, name: "Inline", key: "IN" }])
  },
  getNotionDatabases: () => {
    calls.push("getNotionDatabases")
    return Effect.succeed([{ id: notionDatabaseId, title: "Tasks" }])
  },
  saveLinearTeamId: () => {
    calls.push("saveLinearTeamId")
    return Effect.void
  },
  saveNotionDatabaseId: () => {
    calls.push("saveNotionDatabaseId")
    return Effect.void
  },
  ...overrides,
})

const makeUploads = (
  calls: Array<V1MessagingProvidersOperation>,
  overrides: Partial<V1UploadOperationsShape> = {},
): V1UploadOperationsShape => ({
  uploadFile: () => {
    calls.push("uploadFile")
    return Effect.succeed({ fileUniqueId: "INP123", photoId: 1 })
  },
  ...overrides,
})

const makeKernel = ({
  errorReporter = { report: () => Effect.void },
  messaging,
  providers,
  sessionAuthentication = {
    authenticate: () => Effect.succeed(makeSessionIdentity(42, 7)),
  },
  uploads,
}: {
  readonly errorReporter?: ErrorReporterShape
  readonly messaging: V1MessagingOperationsShape
  readonly providers: V1ProviderOperationsShape
  readonly sessionAuthentication?: SessionAuthenticationShape
  readonly uploads: V1UploadOperationsShape
}) => {
  const routeGroup = makeV1MessagingProvidersRouteGroup()
  const uploadAdmission =
    makeV1UploadAdmission()
  const services = Layer.mergeAll(
    Layer.succeed(V1MessagingOperations, messaging),
    Layer.succeed(V1ProviderOperations, providers),
    Layer.succeed(
      V1UploadAdmission,
      uploadAdmission,
    ),
    Layer.succeed(V1UploadOperations, uploads),
    Layer.succeed(SessionAuthentication, sessionAuthentication),
  )
  const application = makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: makePlatformApiBase("https://api.inline.chat").add(V1MessagingProvidersApiGroup),
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: routeGroup.handlers,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: makeBotApiBase("https://api.inline.chat"),
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: Layer.empty,
    }),
    middleware: { isProduction: false },
  }).pipe(
    Layer.provide(BunFileSystem.layer),
    Layer.provide(BunPath.layer),
    Layer.provide(HttpServer.layerServices),
    Layer.provide(EffectErrorReporter.layer([])),
    Layer.provide(Layer.succeed(ErrorReporter, errorReporter)),
    Layer.provide(services),
  )
  const webHandler = HttpRouter.toWebHandler(application, { disableLogger: true })
  const context = Context.make(HttpRequestContext, {
    clientIp: "unresolved-client",
    method: "GET",
    path: "/test",
    requestId: RequestId.make("v1-messaging-providers-test"),
    startedAtMillis: 0,
  }).pipe(
    Context.add(V1MessagingOperations, messaging),
    Context.add(V1ProviderOperations, providers),
    Context.add(
      V1UploadAdmission,
      uploadAdmission,
    ),
    Context.add(V1UploadOperations, uploads),
    Context.add(SessionAuthentication, sessionAuthentication),
    Context.add(ErrorReporter, errorReporter),
    Context.merge(bunFileContext),
  )
  return {
    dispose: webHandler.dispose,
    handler: (request: Request) => webHandler.handler(request, context),
  }
}

const routeCases: ReadonlyArray<{
  readonly operation: Exclude<V1MessagingProvidersOperation, "uploadFile">
  readonly input: Readonly<Record<string, unknown>>
}> = [
  { operation: "addReaction", input: { messageId: 7, chatId: 8, emoji: "👍" } },
  {
    operation: "createLinearIssue",
    input: { text: "Task", messageId: 7, chatId: 8, peerId: { userId: 43 }, fromId: 42, spaceId: 9 },
  },
  { operation: "createNotionTask", input: { spaceId: 9, messageId: 7, chatId: 8, peerId: { userId: 43 } } },
  { operation: "createPrivateChat", input: { userId: "43" } },
  { operation: "createThread", input: { title: "General", spaceId: 9 } },
  { operation: "deleteAttachment", input: { externalTaskId: 1, pageId: "page", messageId: 7, chatId: 8 } },
  { operation: "deleteMessage", input: { messageId: 7, chatId: 8, peerUserId: 43 } },
  { operation: "disconnectIntegration", input: { spaceId: 9, provider: "linear" } },
  { operation: "getAlphaText", input: {} },
  { operation: "getChatHistory", input: { peerUserId: 43, limit: 10 } },
  { operation: "getDialogs", input: { spaceId: 9 } },
  { operation: "getDraft", input: { peerUserId: 43 } },
  { operation: "getIntegrations", input: { userId: 42, spaceId: 9 } },
  { operation: "getLinearTeams", input: { spaceId: 9 } },
  { operation: "getNotionDatabases", input: { spaceId: 9 } },
  { operation: "getPrivateChats", input: {} },
  { operation: "readMessages", input: { peerUserId: 43, maxId: 7 } },
  { operation: "saveLinearTeamId", input: { spaceId: "9", teamId: "team" } },
  { operation: "saveNotionDatabaseId", input: { spaceId: "9", databaseId: "database" } },
  { operation: "sendComposeAction", input: { peerUserId: 43, action: "typing" } },
  { operation: "sendMessage", input: { peerUserId: 43, text: "hello", parseMarkdown: true } },
  { operation: "sendMessage20250509", input: { peerUserId: 43, text: "hello" } },
  { operation: "updateDialog", input: { peerUserId: 43, pinned: true } },
]

const query = (input: Readonly<Record<string, unknown>>) => {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(input)) {
    params.set(key, typeof value === "object" ? JSON.stringify(value) : String(value))
  }
  const encoded = params.toString()
  return encoded === "" ? "" : `?${encoded}`
}

const expectSuccess = async (response: Response) => {
  expect(response.status).toBe(200)
  expect(response.headers.get("content-type")).toContain("application/json")
  expect(await response.json()).toMatchObject({ ok: true })
}

describe("Effect /v1 messaging and provider routes", () => {
  it("bounds concurrent upload admission", async () => {
    const admission =
      makeV1UploadAdmission(1)
    let releaseFirst:
      | (() => void)
      | undefined
    const first =
      Effect.runPromise(
        admission.withPermit(
          Effect.promise(
            () =>
              new Promise<void>(
                (resolve) => {
                  releaseFirst = resolve
                },
              ),
          ),
        ),
      )
    await Promise.resolve()

    let secondEntered = false
    const second =
      Effect.runPromise(
        admission.withPermit(
          Effect.sync(() => {
            secondEntered = true
          }),
        ),
      )
    await Promise.resolve()
    expect(secondEntered).toBe(false)

    releaseFirst?.()
    await Promise.all([
      first,
      second,
    ])
    expect(secondEntered).toBe(true)
  })

  it("serves every retained GET, path-token GET, POST, and multipart form", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    const tokens: Array<string> = []
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
      sessionAuthentication: {
        authenticate: (token) => {
          tokens.push(token)
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    try {
      for (const testCase of routeCases) {
        const suffix = query(testCase.input)
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/${testCase.operation}${suffix}`, {
              headers: { authorization: "Bearer header-token" },
            }),
          ),
        )
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/path-token/${testCase.operation}${suffix}`, {
              headers: { authorization: "Bearer ignored-header-token" },
            }),
          ),
        )
        await expectSuccess(
          await kernel.handler(
            new Request(`http://inline.test/v1/${testCase.operation}`, {
              method: "POST",
              headers: {
                authorization: "Bearer header-token",
                "content-type": "application/json",
              },
              body: JSON.stringify(testCase.input),
            }),
          ),
        )
      }

      const form = new FormData()
      form.set("type", "photo")
      form.set("file", new File(["image"], "inline.png", { type: "image/png" }))
      await expectSuccess(
        await kernel.handler(
          new Request("http://inline.test/v1/uploadFile", {
            method: "POST",
            headers: { authorization: "Bearer header-token" },
            body: form,
          }),
        ),
      )

      for (const testCase of routeCases) {
        expect(calls.filter((operation) => operation === testCase.operation)).toHaveLength(3)
      }
      expect(calls.filter((operation) => operation === "uploadFile")).toHaveLength(1)
      expect(calls).toHaveLength(70)
      expect(tokens.filter((token) => token === "path-token")).toHaveLength(23)
      expect(tokens).not.toContain("ignored-header-token")
    } finally {
      await kernel.dispose()
    }
  })

  it("validates ordinary inputs before auth but authenticates uploads before parsing", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    let authenticationCalls = 0
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
      sessionAuthentication: {
        authenticate: () => {
          authenticationCalls += 1
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/getLinearTeams?spaceId=invalid"),
      )
      expect(response.status).toBe(400)
      expect(await response.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      })
      expect(authenticationCalls).toBe(0)
      expect(calls).toEqual([])

      const emptyUploadResponse =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/uploadFile",
            { method: "POST" },
          ),
        )
      expect(
        emptyUploadResponse.status,
      ).toBe(400)

      const jsonUploadResponse =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/uploadFile",
            {
              method: "POST",
              headers: {
                authorization:
                  "Bearer token",
                "content-type":
                  "application/json",
              },
              body: "{}",
            },
          ),
        )
      expect(
        jsonUploadResponse.status,
      ).toBe(400)
      expect(authenticationCalls).toBe(0)

      const upload = new FormData()
      upload.set("type", "photo")
      const uploadResponse = await kernel.handler(
        new Request("http://inline.test/v1/uploadFile", {
          method: "POST",
          body: upload,
        }),
      )
      expect(uploadResponse.status).toBe(401)
      expect(authenticationCalls).toBe(0)
      expect(calls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("returns upload authentication failures without pulling the request body", async () => {
    let pulls = 0
    const body =
      new ReadableStream<Uint8Array>({
        pull() {
          pulls += 1
        },
      })
    const calls:
      Array<V1MessagingProvidersOperation> =
      []
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })

    try {
      const request =
        new Request(
          "http://inline.test/v1/uploadFile",
          {
            method: "POST",
            headers: {
              "content-type":
                "multipart/form-data; boundary=never-read",
            },
            body,
            duplex: "half",
          } as RequestInit & {
            readonly duplex: "half"
          },
        )
      // A Web ReadableStream fills its initial queue without a consumer.
      await Promise.resolve()
      const pullsBeforeHandling =
        pulls
      const response =
        await kernel.handler(
          request,
        )

      expect(response.status).toBe(401)
      expect(pulls).toBe(
        pullsBeforeHandling,
      )
      expect(calls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("returns 401 for unauthenticated valid multipart and 400 for authenticated malformed multipart", async () => {
    const calls:
      Array<V1MessagingProvidersOperation> =
      []
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })
    const valid =
      new FormData()
    valid.set("type", "photo")
    valid.set(
      "file",
      new File(
        ["image"],
        "inline.png",
        { type: "image/png" },
      ),
    )

    try {
      const unauthorized =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/uploadFile",
            {
              method: "POST",
              body: valid,
            },
          ),
        )
      expect(unauthorized.status).toBe(
        401,
      )

      const malformed =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/uploadFile",
            {
              method: "POST",
              headers: {
                authorization:
                  "Bearer token",
                "content-type":
                  "multipart/form-data; boundary=missing",
              },
              body: "not-multipart",
            },
          ),
        )
      expect(malformed.status).toBe(400)
      expect(
        await malformed.json(),
      ).toMatchObject({
        error: "INVALID_ARGS",
        errorCode: 400,
      })

      const missingFile =
        new FormData()
      missingFile.set("type", "photo")
      const missing =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/uploadFile",
            {
              method: "POST",
              headers: {
                authorization:
                  "Bearer token",
              },
              body: missingFile,
            },
          ),
        )
      expect(missing.status).toBe(400)
      expect(calls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("matches Elysia's query, JSON, and urlencoded coercion matrix", async () => {
    const legacyInputs: Array<unknown> = []
    const replacementInputs: Array<unknown> = []
    const InputId = t.Union([t.String(), t.Integer()])
    const Peer = t.Union([
      t.Object({ userId: t.Integer() }),
      t.Object({ threadId: t.Integer() }),
    ])
    const legacy = new Elysia()
      .onError(({ code, set }) => {
        if (code !== "VALIDATION") return
        set.status = 400
        return {
          ok: false,
          error: "INVALID_ARGS",
          errorCode: 400,
          description: "Validation error",
        }
      })
      .get(
        "/linear",
        ({ query }) => {
          legacyInputs.push(query)
          return { ok: true }
        },
        {
          query: t.Object({
            text: t.String(),
            messageId: t.Number(),
            chatId: t.Number(),
            peerId: Peer,
            fromId: t.Number(),
            spaceId: t.Optional(t.Number()),
          }),
        },
      )
      .post(
        "/linear",
        ({ body }) => {
          legacyInputs.push(body)
          return { ok: true }
        },
        {
          body: t.Object({
            text: t.String(),
            messageId: t.Number(),
            chatId: t.Number(),
            peerId: Peer,
            fromId: t.Number(),
            spaceId: t.Optional(t.Number()),
          }),
        },
      )
      .get(
        "/send",
        ({ query }) => {
          legacyInputs.push(query)
          return { ok: true }
        },
        {
          query: t.Object({
            peerUserId: t.Optional(InputId),
            parseMarkdown: t.Optional(t.Boolean()),
          }),
        },
      )
      .post(
        "/send",
        ({ body }) => {
          legacyInputs.push(body)
          return { ok: true }
        },
        {
          body: t.Object({
            peerUserId: t.Optional(InputId),
            parseMarkdown: t.Optional(t.Boolean()),
          }),
        },
      )
      .post(
        "/history",
        ({ body }) => {
          legacyInputs.push(body)
          return { ok: true }
        },
        {
          body: t.Object({
            peerUserId: t.Optional(InputId),
            limit: t.Optional(t.Integer()),
          }),
        },
      )

    const calls: Array<V1MessagingProvidersOperation> = []
    const kernel = makeKernel({
      messaging: makeMessaging(calls, {
        getChatHistory: (input) => {
          replacementInputs.push(input)
          return Effect.succeed({ messages: [message] })
        },
        sendMessage: (input) => {
          replacementInputs.push(input)
          return Effect.succeed({
            message,
            updates: [{ updateMessageId: { messageId: 7, randomId: "123" } }],
          })
        },
      }),
      providers: makeProviders(calls, {
        createLinearIssue: (input) => {
          replacementInputs.push(input)
          return Effect.succeed({ link: "https://linear.app/issue/INLINE-1" })
        },
      }),
      uploads: makeUploads(calls),
    })
    const json = (path: string, body: unknown) =>
      new Request(`http://localhost${path}`, {
        method: "POST",
        headers: {
          authorization: "Bearer token",
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      })
    const form = (path: string, body: string) =>
      new Request(`http://localhost${path}`, {
        method: "POST",
        headers: {
          authorization: "Bearer token",
          "content-type": "application/x-www-form-urlencoded",
        },
        body,
      })
    const cases = [
      {
        legacy: () =>
          new Request(
            "http://localhost/linear?text=Task&messageId=7&chatId=8&peerId=%7B%22userId%22%3A43%7D&fromId=42&spaceId=9",
          ),
        replacement: () =>
          new Request(
            "http://localhost/v1/createLinearIssue?text=Task&messageId=7&chatId=8&peerId=%7B%22userId%22%3A43%7D&fromId=42&spaceId=9",
            { headers: { authorization: "Bearer token" } },
          ),
      },
      {
        legacy: () =>
          json("/linear", {
            text: "Task",
            messageId: 7,
            chatId: 8,
            peerId: { userId: 43 },
            fromId: 42,
            spaceId: 9,
          }),
        replacement: () =>
          json("/v1/createLinearIssue", {
            text: "Task",
            messageId: 7,
            chatId: 8,
            peerId: { userId: 43 },
            fromId: 42,
            spaceId: 9,
          }),
      },
      {
        legacy: () =>
          json("/linear", {
            text: "Task",
            messageId: "7",
            chatId: "8",
            peerId: { userId: 43 },
            fromId: "42",
            spaceId: "9",
          }),
        replacement: () =>
          json("/v1/createLinearIssue", {
            text: "Task",
            messageId: "7",
            chatId: "8",
            peerId: { userId: 43 },
            fromId: "42",
            spaceId: "9",
          }),
      },
      {
        legacy: () =>
          form(
            "/linear",
            "text=Task&messageId=7&chatId=8&peerId=%7B%22userId%22%3A43%7D&fromId=42&spaceId=9",
          ),
        replacement: () =>
          form(
            "/v1/createLinearIssue",
            "text=Task&messageId=7&chatId=8&peerId=%7B%22userId%22%3A43%7D&fromId=42&spaceId=9",
          ),
      },
      {
        legacy: () =>
          new Request("http://localhost/send?peerUserId=43&parseMarkdown=false"),
        replacement: () =>
          new Request(
            "http://localhost/v1/sendMessage?peerUserId=43&parseMarkdown=false",
            { headers: { authorization: "Bearer token" } },
          ),
      },
      {
        legacy: () =>
          json("/send", { peerUserId: "43", parseMarkdown: "false" }),
        replacement: () =>
          json("/v1/sendMessage", {
            peerUserId: "43",
            parseMarkdown: "false",
          }),
      },
      {
        legacy: () =>
          form("/send", "peerUserId=43&parseMarkdown=false"),
        replacement: () =>
          form("/v1/sendMessage", "peerUserId=43&parseMarkdown=false"),
      },
      {
        legacy: () =>
          json("/history", { peerUserId: "43", limit: "20" }),
        replacement: () =>
          json("/v1/getChatHistory", {
            peerUserId: "43",
            limit: "20",
          }),
      },
      {
        legacy: () =>
          form("/history", "peerUserId=43&limit=20"),
        replacement: () =>
          form("/v1/getChatHistory", "peerUserId=43&limit=20"),
      },
    ] as const

    try {
      for (const testCase of cases) {
        const legacyResponse = await legacy.handle(testCase.legacy())
        const replacementResponse = await kernel.handler(testCase.replacement())
        expect(replacementResponse.status).toBe(legacyResponse.status)
      }
      expect(replacementInputs).toEqual(legacyInputs)
    } finally {
      await kernel.dispose()
    }
  })

  it("persists same-named file fields to distinct scoped paths", async () => {
    const calls:
      Array<V1MessagingProvidersOperation> =
      []
    let observed:
      | ReadonlyArray<string>
      | undefined
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls, {
        uploadFile: (input) =>
          Effect.promise(async () => {
            calls.push("uploadFile")
            observed = [
              await input.file!.text(),
              await input.thumbnail!.text(),
            ]
            return {
              fileUniqueId: "INP123",
              videoId: 1,
            }
          }),
      }),
    })

    try {
      const response =
        await kernel.handler(
          makeMultipartRequest(
            [
              {
                name: "type",
                value: "video",
              },
              {
                name: "file",
                value: "video",
                filename: "same.bin",
                contentType:
                  "application/octet-stream",
              },
              {
                name: "thumbnail",
                value: "thumbnail",
                filename: "same.bin",
                contentType:
                  "application/octet-stream",
              },
            ],
            {
              authorization:
                "Bearer token",
            },
          ),
        )

      expect(response.status).toBe(200)
      expect(observed).toEqual([
        "video",
        "thumbnail",
      ])
      expect(calls).toEqual([
        "uploadFile",
      ])
    } finally {
      await kernel.dispose()
    }
  })

  it("bounds authenticated upload content length, fields, duplicate parts, and chunked parsing", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    let authenticationCalls = 0
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
      sessionAuthentication: {
        authenticate: () => {
          authenticationCalls += 1
          return Effect.succeed(makeSessionIdentity(42, 7))
        },
      },
    })

    const request = (
      parts: ReadonlyArray<MultipartTestPart>,
      headers: HeadersInit = {},
    ) =>
      makeMultipartRequest(parts, {
        authorization: "Bearer token",
        ...headers,
      })

    try {
      const lengthResponse = await kernel.handler(
        request(
          [
            { name: "type", value: "photo" },
            {
              name: "file",
              value: "image",
              filename: "inline.png",
              contentType: "image/png",
            },
          ],
          {
            "content-length": String(defaultV1UploadLimits.maxTotalSize + 1),
          },
        ),
      )
      expect(lengthResponse.status).toBe(400)
      expect(await lengthResponse.json()).toMatchObject({
        error: "FILE_TOO_LARGE",
        errorCode: 400,
      })

      const fieldRequest = request([
        { name: "type", value: "photo" },
        {
          name: "file",
          value: "image",
          filename: "inline.png",
          contentType: "image/png",
        },
        {
          name: "width",
          value: "x".repeat(defaultV1UploadLimits.maxFieldSize + 1),
        },
      ])
      expect(fieldRequest.headers.get("content-length")).toBeNull()
      const fieldResponse = await kernel.handler(fieldRequest)
      expect(fieldResponse.status).toBe(400)

      const duplicateResponse = await kernel.handler(
        request([
          { name: "type", value: "photo" },
          {
            name: "file",
            value: "one",
            filename: "one.png",
            contentType: "image/png",
          },
          {
            name: "file",
            value: "two",
            filename: "two.png",
            contentType: "image/png",
          },
        ]),
      )
      expect(duplicateResponse.status).toBe(400)

      const countParts: Array<MultipartTestPart> = [
        { name: "type", value: "photo" },
        {
          name: "file",
          value: "image",
          filename: "inline.png",
          contentType: "image/png",
        },
      ]
      for (let index = 0; index < defaultV1UploadLimits.maxParts; index += 1) {
        countParts.push({ name: "width", value: String(index) })
      }
      const countResponse = await kernel.handler(request(countParts))
      expect(countResponse.status).toBe(400)

      expect(authenticationCalls).toBe(3)
      expect(calls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("enforces streamed per-file and total upload limits without Content-Length", async () => {
    const request = () =>
      makeMultipartRequest([
        { name: "type", value: "photo" },
        {
          name: "file",
          value: "image",
          filename: "inline.png",
          contentType: "image/png",
        },
      ])
    expect(request().headers.get("content-length")).toBeNull()

    const fileError = await Effect.runPromise(
      Effect.scoped(
        Effect.flip(
          parseV1UploadRequest(HttpServerRequest.fromWeb(request()), {
            maxFieldSize: 1024,
            maxFileSize: 3,
            maxThumbnailFileSize: 3,
            maxParts: 9,
            maxTotalSize: 4096,
          }),
        ),
      ).pipe(
        Effect.provide([
          BunFileSystem.layer,
          BunPath.layer,
        ]),
      ),
    )
    expect(fileError).toMatchObject({
      _tag: "V1MessagingProvidersPublicError",
      error: "FILE_TOO_LARGE",
    })

    const totalError = await Effect.runPromise(
      Effect.scoped(
        Effect.flip(
          parseV1UploadRequest(HttpServerRequest.fromWeb(request()), {
            maxFieldSize: 1024,
            maxFileSize: 1024,
            maxThumbnailFileSize: 1024,
            maxParts: 9,
            maxTotalSize: 32,
          }),
        ),
      ).pipe(
        Effect.provide([
          BunFileSystem.layer,
          BunPath.layer,
        ]),
      ),
    )
    expect(totalError).toMatchObject({
      _tag: "V1MessagingProvidersPublicError",
      error: "FILE_TOO_LARGE",
    })
  })

  it("keeps sendMessage20250509 request validation in the standard envelope", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    const kernel = makeKernel({
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/sendMessage20250509?peerId=%7B%7D", {
          headers: { authorization: "Bearer token" },
        }),
      )
      expect(response.status).toBe(400)
      expect(await response.json()).toEqual({
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      })
      expect(calls).toEqual([])
    } finally {
      await kernel.dispose()
    }
  })

  it("uses the Bot-compatible envelope only for sendMessage20250509 operation failures", async () => {
    const calls:
      Array<V1MessagingProvidersOperation> =
      []
    const kernel = makeKernel({
      messaging: makeMessaging(calls, {
        sendMessage20250509: () =>
          Effect.fail(
            new V1MessagingProvidersPublicError({
              error: "PEER_INVALID",
              errorCode: 400,
              description:
                "Invalid peer",
            }),
          ),
      }),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })

    try {
      const response =
        await kernel.handler(
          new Request(
            "http://inline.test/v1/sendMessage20250509",
            {
              method: "POST",
              headers: {
                authorization:
                  "Bearer token",
                "content-type":
                  "application/json",
              },
              body: JSON.stringify({
                peerUserId: 43,
                text: "hello",
              }),
            },
          ),
        )

      expect(response.status).toBe(400)
      expect(
        await response.json(),
      ).toEqual({
        ok: false,
        error: "PEER_INVALID",
        error_code: 400,
        description: "Invalid peer",
      })
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves standard versus Bot-compatible auth and malformed-JSON envelopes", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    const reports: Array<unknown> = []
    const kernel = makeKernel({
      errorReporter: {
        report: (failure) => Effect.sync(() => reports.push(failure)),
      },
      messaging: makeMessaging(calls),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })

    try {
      const unauthorized = await kernel.handler(
        new Request("http://inline.test/v1/getAlphaText"),
      )
      expect(unauthorized.status).toBe(401)
      expect(await unauthorized.json()).toMatchObject({
        ok: false,
        errorCode: 401,
      })

      for (
        const operation of [
          "getAlphaText",
          "getChatHistory",
          "getPrivateChats",
        ] as const
      ) {
        const emptyPost =
          await kernel.handler(
            new Request(
              `http://inline.test/v1/${operation}`,
              { method: "POST" },
            ),
          )
        expect(emptyPost.status).toBe(
          401,
        )
        expect(
          await emptyPost.json(),
        ).toMatchObject({
          error: "UNAUTHORIZED",
          errorCode: 401,
        })
      }

      const malformed = await kernel.handler(
        new Request("http://inline.test/v1/getDraft", {
          method: "POST",
          headers: {
            authorization: "Bearer token",
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformed.status).toBe(500)
      expect(await malformed.json()).toMatchObject({
        ok: false,
        errorCode: 500,
      })

      const malformedCompat = await kernel.handler(
        new Request("http://inline.test/v1/sendMessage20250509", {
          method: "POST",
          headers: {
            authorization: "Bearer token",
            "content-type": "application/json",
          },
          body: "{",
        }),
      )
      expect(malformedCompat.status).toBe(500)
      expect(await malformedCompat.json()).toMatchObject({
        ok: false,
        errorCode: 500,
      })
      expect(calls).toEqual([])
      expect(reports).toHaveLength(2)
    } finally {
      await kernel.dispose()
    }
  })

  it("reports a server failure once without exposing its cause", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    const reported: Array<unknown> = []
    const kernel = makeKernel({
      errorReporter: {
        report: (failure) => Effect.sync(() => reported.push(failure)),
      },
      messaging: makeMessaging(calls),
      providers: makeProviders(calls, {
        getLinearTeams: () =>
          Effect.fail(
            new V1MessagingProvidersOperationFailure({
              operation: "v1.getLinearTeams",
              cause: new Error("provider token must stay private"),
            }),
          ),
      }),
      uploads: makeUploads(calls),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/getLinearTeams?spaceId=9", {
          headers: { authorization: "Bearer token" },
        }),
      )
      expect(response.status).toBe(500)
      const body = await response.json()
      expect(body).toEqual({
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      })
      expect(reported).toHaveLength(1)
      expect(JSON.stringify(body)).not.toContain("provider token")
    } finally {
      await kernel.dispose()
    }
  })

  it("preserves declared public errors", async () => {
    const calls: Array<V1MessagingProvidersOperation> = []
    const kernel = makeKernel({
      messaging: makeMessaging(calls, {
        getDraft: () =>
          Effect.fail(
            new V1MessagingProvidersPublicError({
              error: "PEER_INVALID",
              errorCode: 400,
              description: "Invalid peer",
            }),
          ),
      }),
      providers: makeProviders(calls),
      uploads: makeUploads(calls),
    })

    try {
      const response = await kernel.handler(
        new Request("http://inline.test/v1/getDraft?peerUserId=43", {
          headers: { authorization: "Bearer token" },
        }),
      )
      expect(response.status).toBe(400)
      expect(await response.json()).toEqual({
        ok: false,
        error: "PEER_INVALID",
        errorCode: 400,
        description: "Invalid peer",
      })
    } finally {
      await kernel.dispose()
    }
  })
})
