import { Effect } from "effect"
import { HttpServerRequest } from "effect/unstable/http"
import { parseLegacyElysiaBody } from "../core/http/legacyElysiaBody"
import type { V1MessagingProvidersOperation } from "./v1MessagingProvidersContracts.effect"
import { V1MessagingProvidersRequestFailure } from "./v1MessagingProvidersErrors.effect"
import { parseV1UploadRequest } from "./v1UploadRequest.effect"

const queryNumberFields: Partial<Record<V1MessagingProvidersOperation, ReadonlyArray<string>>> = {
  createLinearIssue: ["messageId", "chatId", "fromId", "spaceId"],
  createNotionTask: ["spaceId", "messageId", "chatId"],
  deleteAttachment: ["externalTaskId", "messageId", "chatId"],
  disconnectIntegration: ["spaceId"],
  getLinearTeams: ["spaceId"],
  getNotionDatabases: ["spaceId"],
}

const transformedIntegerFields: Partial<Record<V1MessagingProvidersOperation, ReadonlyArray<string>>> = {
  getChatHistory: ["limit"],
  readMessages: ["maxId"],
}

const booleanFields: Partial<Record<V1MessagingProvidersOperation, ReadonlyArray<string>>> = {
  sendMessage: ["isSticker", "parseMarkdown"],
  updateDialog: ["pinned", "archived"],
}

export type V1MessagingProvidersInputSource =
  | "json"
  | "multipart"
  | "query"
  | "urlencoded"
  | "unsupported"

/**
 * Reproduces Elysia's media-specific coercion while preserving raw
 * compatibility IDs. Plain `Type.Number` / `Type.Boolean` fields coerce only
 * from query input; legacy `Type.Integer` transforms also coerce body fields.
 */
export const normalizeV1MessagingProvidersInput = (
  operation: V1MessagingProvidersOperation,
  input: unknown,
  source: V1MessagingProvidersInputSource,
): unknown => {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return input
  }

  let changed = false
  const normalized: Record<string, unknown> = { ...(input as Record<string, unknown>) }
  const integerFields = [
    ...(transformedIntegerFields[operation] ?? []),
    ...(source === "query" ? queryNumberFields[operation] ?? [] : []),
  ]
  for (const key of integerFields) {
    if (typeof normalized[key] === "string" && normalized[key] !== "") {
      normalized[key] = Number(normalized[key])
      changed = true
    }
  }
  for (const key of source === "query" ? booleanFields[operation] ?? [] : []) {
    if (typeof normalized[key] === "string") {
      if (normalized[key] === "true") {
        normalized[key] = true
        changed = true
      } else if (normalized[key] === "false") {
        normalized[key] = false
        changed = true
      }
    }
  }

  if (
    source === "query" &&
    typeof normalized["peerId"] === "string" &&
    normalized["peerId"].startsWith("{")
  ) {
    try {
      normalized["peerId"] = JSON.parse(normalized["peerId"])
      changed = true
    } catch {
      // Leave malformed input for the Effect Schema boundary.
    }
  }

  if (source === "query") {
    const peerId = normalized["peerId"]
    if (peerId !== null && typeof peerId === "object" && !Array.isArray(peerId)) {
      const peer = peerId as Record<string, unknown>
      for (const key of ["userId", "threadId"]) {
        if (typeof peer[key] === "string" && peer[key] !== "") {
          normalized["peerId"] = {
            ...peer,
            [key]: Number(peer[key]),
          }
          changed = true
          break
        }
      }
    }
  }

  return changed ? normalized : input
}

const mediaType = (request: Request): string | undefined =>
  request.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase()

const inputSource = (request: Request): V1MessagingProvidersInputSource => {
  if (request.method === "GET") return "query"
  switch (mediaType(request)) {
    case "application/json":
      return "json"
    case "application/x-www-form-urlencoded":
      return "urlencoded"
    case "multipart/form-data":
      return "multipart"
    default:
      return "unsupported"
  }
}

const bodyToInput = async (request: Request, operation: V1MessagingProvidersOperation): Promise<unknown> => {
  const source = inputSource(request)
  const input = source === "query"
    ? Object.fromEntries(new URL(request.url).searchParams)
    : await parseLegacyElysiaBody(request)
  const acceptsAbsentObject =
    operation === "getAlphaText" ||
    operation === "getChatHistory" ||
    operation === "getPrivateChats"
  return normalizeV1MessagingProvidersInput(
    operation,
    input === undefined &&
        acceptsAbsentObject
      ? {}
      : input,
    source,
  )
}

export const toV1MessagingProvidersWebRequest = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  HttpServerRequest.toWeb(request).pipe(
    Effect.mapError(
      (cause) =>
        new V1MessagingProvidersRequestFailure({
          operation: "v1.request",
          cause,
        }),
    ),
  )

export const prepareV1MessagingProvidersRequest = (
  request: HttpServerRequest.HttpServerRequest,
  operation: V1MessagingProvidersOperation,
  webRequest?: Request,
) =>
  Effect.gen(function* () {
    const preparedWebRequest =
      webRequest ??
      (yield* toV1MessagingProvidersWebRequest(
        request,
      ).pipe(
        Effect.mapError(
          (error) =>
            new V1MessagingProvidersRequestFailure({
              operation:
                `v1.${operation}.request`,
              cause: error.cause,
            }),
        ),
      ))
    const input = operation === "uploadFile"
      ? yield* parseV1UploadRequest(request)
      : yield* Effect.tryPromise({
          try: () => bodyToInput(preparedWebRequest, operation),
          catch: (cause) =>
            new V1MessagingProvidersRequestFailure({
              operation: `v1.${operation}.request`,
              cause,
            }),
        })
    return {
      input,
      webRequest: preparedWebRequest,
    }
  })
