import { describe, expect, it } from "@effect/vitest"
import { Effect, Schema } from "effect"
import { handler as legacyGetAlphaText } from "@in/server/methods/getAlphaText"
import { InlineError } from "../types/errors"
import { validateUploadFileMetadata } from "../methods/uploadFileMetadata"
import { makeSessionIdentity } from "./plugins.effect"
import {
  V1MessagingProvidersOperationFailure,
  V1MessagingProvidersPublicError,
  V1MessagingProvidersResponseContractFailure,
} from "./v1MessagingProvidersErrors.effect"
import { invokeLegacyV1Operation } from "./v1MessagingProvidersOperationsAdapter.effect"
import { alphaWelcomeText, getAlphaTextEffect } from "./v1MessagingOperationsAdapter.effect"
import { normalizeV1MessagingProvidersInput } from "./v1MessagingProvidersRequest.effect"
import { makeV1ProviderOperations } from "./v1ProviderOperationsAdapter.effect"
import { makeProviderTaskAuthorizer } from "./v1ProviderTaskAuthorization"
import { UploadFileResult } from "./v1UploadSchemas.effect"
import {
  CreateLinearIssueInput,
  CreateNotionTaskInput,
  GetIntegrationsResult,
  GetNotionDatabasesInput,
} from "./v1ProviderSchemas.effect"

const decode = <A>(
  schema: Schema.Decoder<A>,
  input: unknown,
): A => Schema.decodeUnknownSync(schema)(input)

describe("Effect /v1 messaging and provider operations", () => {
  it.effect("keeps the Effect-native alpha text byte-for-byte compatible", () =>
    Effect.gen(function* () {
      const effectText = yield* getAlphaTextEffect
      const legacyText = yield* Effect.promise(() =>
        legacyGetAlphaText({}, {
          currentUserId: 42,
          currentSessionId: 7,
          ip: undefined,
        }),
      )
      expect(effectText).toBe(alphaWelcomeText)
      expect(effectText).toBe(legacyText)
    }),
  )

  it.effect("keeps declared Inline failures typed", () =>
    Effect.gen(function* () {
      const result = yield* Effect.flip(
        invokeLegacyV1Operation("v1.test", Schema.String, async () => {
          throw new InlineError(InlineError.ApiError.BAD_REQUEST)
        }),
      )
      expect(result).toBeInstanceOf(V1MessagingProvidersPublicError)
      expect(result).toMatchObject({
        errorCode: 400,
      })
    }),
  )

  it.effect("retains private causes for unexpected failures", () =>
    Effect.gen(function* () {
      const cause = new Error("private provider response")
      const result = yield* Effect.flip(
        invokeLegacyV1Operation("v1.test", Schema.String, async () => {
          throw cause
        }),
      )
      expect(result).toBeInstanceOf(V1MessagingProvidersOperationFailure)
      if (result._tag !== "V1MessagingProvidersOperationFailure") {
        throw new Error("expected operation failure")
      }
      expect(result).toMatchObject({
        operation: "v1.test",
        cause,
      })
    }),
  )

  it.effect("retains an INTERNAL sentinel privately while keeping its public envelope stable", () =>
    Effect.gen(function* () {
      const sentinel = new Error("private provider sentinel")
      const result = yield* Effect.flip(
        invokeLegacyV1Operation("v1.test", Schema.String, async () => {
          throw new InlineError(InlineError.ApiError.INTERNAL, {
            cause: sentinel,
          })
        }),
      )
      expect(result).toBeInstanceOf(V1MessagingProvidersOperationFailure)
      if (result._tag !== "V1MessagingProvidersOperationFailure") {
        throw new Error("expected operation failure")
      }
      expect(result).toMatchObject({
        cause: sentinel,
        publicError: {
          error: "INTERNAL",
          errorCode: 500,
          description: "Internal server error happened",
        },
      })
      expect(JSON.stringify(result.publicError)).not.toContain("private provider")
    }),
  )

  it.effect("reports response contract drift without retaining the response value", () =>
    Effect.gen(function* () {
      const result = yield* Effect.flip(
        invokeLegacyV1Operation("v1.test", Schema.String, async () => ({
          secret: "must not enter the reporter payload",
        })),
      )
      expect(result).toBeInstanceOf(V1MessagingProvidersOperationFailure)
      if (result._tag !== "V1MessagingProvidersOperationFailure") {
        throw new Error("expected operation failure")
      }
      expect(result.operation).toBe("v1.test.response")
      expect(result.cause).toBeInstanceOf(V1MessagingProvidersResponseContractFailure)
      expect(JSON.stringify(result)).not.toContain("must not enter")
    }),
  )

  it.effect("accepts the retained upload operation's explicit undefined media IDs", () =>
    Effect.gen(function* () {
      const result = yield* invokeLegacyV1Operation(
        "v1.uploadFile",
        UploadFileResult,
        async () => ({
          fileUniqueId: "INP123",
          photoId: 42,
          videoId: undefined,
          documentId: undefined,
          voiceId: undefined,
        }),
      )
      expect(result).toEqual({
        fileUniqueId: "INP123",
        photoId: 42,
      })
    }),
  )

  it.effect("accepts the retained integrations operation's explicit undefined properties", () =>
    Effect.gen(function* () {
      const result = yield* invokeLegacyV1Operation(
        "v1.getIntegrations",
        GetIntegrationsResult,
        async () => ({
          hasLinearConnected: false,
          hasNotionConnected: false,
          hasIntegrationAccess: false,
          linearTeamId: undefined,
          notionDatabaseId: undefined,
          notionSpaces: undefined,
          linearSpaces: undefined,
        }),
      )
      expect(result).toEqual({
        hasLinearConnected: false,
        hasNotionConnected: false,
        hasIntegrationAccess: false,
      })
    }),
  )

  it("coerces query Type.Number fields without widening JSON or form bodies", () => {
    expect(
      normalizeV1MessagingProvidersInput("createLinearIssue", {
        chatId: "8",
        messageId: "7",
        fromId: "42",
        spaceId: "9",
        peerId: "{\"userId\":43}",
      }, "query"),
    ).toEqual({
      chatId: 8,
      messageId: 7,
      fromId: 42,
      spaceId: 9,
      peerId: { userId: 43 },
    })
    expect(
      normalizeV1MessagingProvidersInput("sendMessage", {
        peerUserId: "43",
        parseMarkdown: "false",
      }, "query"),
    ).toEqual({
      peerUserId: "43",
      parseMarkdown: false,
    })
    const json = {
      chatId: "8",
      messageId: "7",
      fromId: "42",
      spaceId: "9",
      peerId: { userId: "43" },
    }
    expect(
      normalizeV1MessagingProvidersInput("createLinearIssue", json, "json"),
    ).toBe(json)
    expect(
      normalizeV1MessagingProvidersInput("createLinearIssue", json, "urlencoded"),
    ).toBe(json)
  })

  it("keeps legacy Type.Integer transforms for JSON and form bodies", () => {
    expect(
      normalizeV1MessagingProvidersInput(
        "getChatHistory",
        { limit: "20" },
        "json",
      ),
    ).toEqual({ limit: 20 })
    expect(
      normalizeV1MessagingProvidersInput(
        "readMessages",
        { maxId: "7", peerUserId: "43" },
        "urlencoded",
      ),
    ).toEqual({ maxId: 7, peerUserId: "43" })
  })

  it.effect("authorizes Notion space access before invoking the retained provider", () =>
    Effect.gen(function* () {
      let listed = false
      const operations = makeV1ProviderOperations({
        authorizeLinearIssue: async () => undefined,
        authorizeNotionTask: async () => undefined,
        authorizeNotionSpace: async () => {
          throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
        },
        createLinearIssue: async () => undefined,
        createNotionTask: async () => undefined,
        deleteAttachment: async () => undefined,
        disconnectIntegration: async () => undefined,
        getIntegrations: async () => undefined,
        getLinearTeams: async () => undefined,
        getNotionDatabases: async () => {
          listed = true
          return []
        },
        saveLinearTeamId: async () => undefined,
        saveNotionDatabaseId: async () => undefined,
      })
      const identity = makeSessionIdentity(42, 7)
      const failure = yield* Effect.flip(
        operations.getNotionDatabases(
          decode(GetNotionDatabasesInput, {
            spaceId: 9,
          }),
          {
            currentUserId: identity.userId,
            currentSessionId: identity.sessionId,
            ip: undefined,
          },
        ),
      )

      expect(failure).toBeInstanceOf(V1MessagingProvidersPublicError)
      expect(listed).toBe(false)
    }),
  )

  it.effect("denies both task providers before invoking retained provider work", () =>
    Effect.gen(function* () {
      const providerCalls: Array<string> = []
      const authorizationError = new InlineError(
        InlineError.ApiError.USER_NOT_PARTICIPANT,
      )
      const operations = makeV1ProviderOperations({
        authorizeLinearIssue: async () => {
          throw authorizationError
        },
        authorizeNotionTask: async () => {
          throw authorizationError
        },
        authorizeNotionSpace: async () => undefined,
        createLinearIssue: async () => {
          providerCalls.push("linear")
          return { link: "https://linear.app/issue/INLINE-1" }
        },
        createNotionTask: async () => {
          providerCalls.push("notion")
          return { url: "https://notion.so/task", taskTitle: "Task" }
        },
        deleteAttachment: async () => undefined,
        disconnectIntegration: async () => undefined,
        getIntegrations: async () => undefined,
        getLinearTeams: async () => undefined,
        getNotionDatabases: async () => undefined,
        saveLinearTeamId: async () => undefined,
        saveNotionDatabaseId: async () => undefined,
      })
      const context = {
        currentUserId: makeSessionIdentity(42, 7).userId,
        currentSessionId: makeSessionIdentity(42, 7).sessionId,
        ip: undefined,
      }

      const linear = yield* Effect.flip(
        operations.createLinearIssue(
          decode(CreateLinearIssueInput, {
            text: "Task",
            messageId: 7,
            chatId: 8,
            peerId: { userId: 43 },
            fromId: 42,
            spaceId: 9,
          }),
          context,
        ),
      )
      const notion = yield* Effect.flip(
        operations.createNotionTask(
          decode(CreateNotionTaskInput, {
            spaceId: 9,
            messageId: 7,
            chatId: 8,
            peerId: { userId: 43 },
          }),
          context,
        ),
      )

      expect(linear).toBeInstanceOf(V1MessagingProvidersPublicError)
      expect(notion).toBeInstanceOf(V1MessagingProvidersPublicError)
      expect(providerCalls).toEqual([])
    }),
  )

  it("requires exact peer, space, and message relationships", async () => {
    const checks: Array<string> = []
    const authorize = makeProviderTaskAuthorizer({
      getAuthorizedChat: async () => ({
        id: 8,
        type: "private",
        minUserId: 42,
        maxUserId: 43,
        spaceId: 9,
      }),
      hasMessage: async (chatId, messageId) => {
        checks.push(`message:${chatId}:${messageId}`)
        return messageId === 7
      },
      requireSpaceMember: async (spaceId, userId) => {
        checks.push(`space:${spaceId}:${userId}`)
      },
    })

    await expect(
      authorize(
        {
          chatId: 8,
          messageId: 7,
          peerId: { userId: 99 },
          spaceId: 9,
        },
        { currentUserId: 42 },
      ),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })
    expect(checks).toEqual([])

    await expect(
      authorize(
        {
          chatId: 8,
          messageId: 7,
          peerId: { userId: 43 },
          spaceId: 10,
        },
        { currentUserId: 42 },
      ),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })
    expect(checks).toEqual([])

    await expect(
      authorize(
        {
          chatId: 8,
          messageId: 99,
          peerId: { userId: 43 },
          spaceId: 9,
        },
        { currentUserId: 42 },
      ),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })
    expect(checks).toEqual(["space:9:42", "message:8:99"])
  })

  it("rejects invalid upload metadata before storage work", () => {
    expect(() =>
      validateUploadFileMetadata({
        type: "video",
        width: "1280",
        height: "720",
      }),
    ).toThrow(expect.objectContaining({
      type: "BAD_REQUEST",
      description: "Video upload requires width, height, and duration",
    }))
    expect(() =>
      validateUploadFileMetadata({
        type: "photo",
        isAnimated: "true",
      }),
    ).toThrow(expect.objectContaining({
      type: "BAD_REQUEST",
      description: "Animated/audio video metadata is only valid for video uploads",
    }))
    expect(() =>
      validateUploadFileMetadata({
        type: "voice",
        duration: "1",
        waveform: "not-base64",
      }),
    ).toThrow(expect.objectContaining({
      type: "BAD_REQUEST",
      description: "Invalid waveform: expected base64 data",
    }))
  })
})
