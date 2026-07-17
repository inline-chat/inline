import { Layer } from "effect"
import {
  HttpRouter,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApi,
  HttpApiSwagger,
  OpenApi,
  type HttpApiGroup,
} from "effect/unstable/httpapi"
import { usesLegacySetupMiddleware } from "./legacySetupCompatibility"

const INLINE_API_VERSION = "0.0.1"

export const PLATFORM_API_ID = "inline-platform-api"
export const BOT_API_ID = "inline-bot-api"

const inlineContact = {
  email: "hi@inline.chat",
  name: "Inline Team",
  url: "https://inline.chat",
} as const

export const BOT_API_DESCRIPTION = [
  "## Authentication",
  "",
  "Recommended: send the bot token via the `Authorization: Bearer <token>` header.",
  "",
  "Alternative: include the token in the URL path using `/bot<token>/<method>`.",
  "",
  "For method parameters, use JSON request body (recommended). Query parameters on POST are also accepted for compatibility.",
  "",
  "Tokens look like `123:IN...` and contain a `:`. Most HTTP clients handle this in the path fine, but if yours doesn't, URL-encode the token segment (e.g. `:` -> `%3A`).",
  "",
  "### Header auth (recommended)",
  "",
  "```bash",
  "curl -sS \\",
  "  -H 'Authorization: Bearer <token>' \\",
  "  -H 'Content-Type: application/json' \\",
  "  -X POST 'https://api.inline.chat/bot/sendMessage' \\",
  "  -d '{\"user_id\": 1001, \"text\": \"hello from bot\"}'",
  "```",
  "",
  "### Token in path",
  "",
  "```bash",
  "curl -sS \\",
  "  -H 'Content-Type: application/json' \\",
  "  -X POST 'https://api.inline.chat/bot<token>/sendMessage' \\",
  "  -d '{\"chat_id\": 42, \"text\": \"hello from bot\"}'",
  "```",
  "",
  "Targeting: use `chat_id` for chats/threads or `user_id` for DMs.",
  "",
  "Errors return `{ \"ok\": false, \"error_code\": <http status>, \"description\": \"...\" }`; `error` may be present as a machine-readable code.",
  "",
  "### Quick check",
  "",
  "```bash",
  "curl -sS 'https://api.inline.chat/bot<token>/getMe'",
  "```",
].join("\n")

export const requireOpenApiRequestHeader = (
  name: string,
  description?: string,
) =>
  OpenApi.annotations({
    transform: (operation) => {
      for (const parameter of operation["parameters"] ?? []) {
        if (
          "in" in parameter &&
          parameter.in === "header" &&
          parameter.name.toLowerCase() === name.toLowerCase()
        ) {
          parameter.required = true
          if (
            description !== undefined &&
            parameter.description === undefined
          ) {
            parameter.description = description
          }
        }
      }
      return operation
    },
  })

const apiInfo = (title: string, description?: string) => ({
  title,
  version: INLINE_API_VERSION,
  ...(description === undefined ? {} : { description }),
  contact: inlineContact,
  termsOfService: "https://inline.chat/terms",
})

const globalRateLimitResponse = {
  description: "The global request quota was exceeded.",
  headers: {
    "RateLimit-Limit": {
      description: "Maximum requests allowed in the current window.",
      schema: { type: "integer", minimum: 1 },
    },
    "RateLimit-Remaining": {
      description: "Requests remaining in the current window.",
      schema: { type: "integer", minimum: 0 },
    },
    "RateLimit-Reset": {
      description: "Whole seconds until the current window resets.",
      schema: { type: "integer", minimum: 0 },
    },
    "Retry-After": {
      description: "Whole seconds to wait before retrying.",
      required: true,
      schema: { type: "integer", minimum: 0 },
    },
  },
  content: {
    "application/json": {
      schema: {
        type: "object",
        additionalProperties: false,
        required: [
          "ok",
          "error",
          "errorCode",
          "description",
        ],
        properties: {
          ok: { const: false },
          error: { const: "FLOOD" },
          errorCode: { const: 420 },
          description: {
            const: "Too many requests. Please wait a bit before retrying.",
          },
        },
      },
    },
  },
} as const

const addGlobalRateLimitResponse = (
  input: Record<string, unknown>,
): Record<string, unknown> => {
  const paths = input["paths"]
  if (paths === null || typeof paths !== "object") {
    return input
  }

  for (const [path, pathItem] of Object.entries(paths)) {
    if (!usesLegacySetupMiddleware(path)) {
      continue
    }
    if (pathItem === null || typeof pathItem !== "object") {
      continue
    }
    for (const operation of Object.values(pathItem)) {
      if (operation === null || typeof operation !== "object") {
        continue
      }
      const operationRecord = operation as Record<string, unknown>
      const responses = operationRecord["responses"]
      if (responses === null || typeof responses !== "object") {
        continue
      }
      operationRecord["responses"] = {
        ...responses,
        "420": globalRateLimitResponse,
      }
    }
  }

  return input
}

const annotateApi = <Id extends string, Groups extends HttpApiGroup.Constraint>(
  api: HttpApi.HttpApi<Id, Groups>,
  {
    apiBaseUrl,
    description,
    title,
  }: {
    readonly apiBaseUrl: string
    readonly description?: string | undefined
    readonly title: string
  },
): HttpApi.HttpApi<Id, Groups> =>
  api.annotateMerge(
    OpenApi.annotations({
      servers: [
        {
          url: apiBaseUrl,
          description: "Production API server",
        },
      ],
      override: {
        info: apiInfo(title, description),
      },
      transform: addGlobalRateLimitResponse,
    }),
  )

/**
 * Stable API identities used by every route-family slice.
 *
 * A slice adds its group to the relevant base before building handlers. The
 * final aggregate keeps the same API identifier, so its handler service keys
 * remain compatible without shared-file edits.
 */
export const makePlatformApiBase = (apiBaseUrl: string) =>
  annotateApi(HttpApi.make(PLATFORM_API_ID), {
    apiBaseUrl,
    title: "Inline HTTP API Docs",
  })

export const makeBotApiBase = (apiBaseUrl: string) =>
  annotateApi(HttpApi.make(BOT_API_ID), {
    apiBaseUrl,
    description: BOT_API_DESCRIPTION,
    title: "Inline Bot HTTP API Docs",
  })

export interface OpenApiDocumentDefinition<
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
> {
  readonly api: HttpApi.HttpApi<Id, Groups>
  readonly jsonPath: `/${string}`
  readonly swaggerPath: `/${string}`
}

export const defineOpenApiDocument = <
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
>(
  definition: OpenApiDocumentDefinition<Id, Groups>,
): OpenApiDocumentDefinition<Id, Groups> => definition

const sortRecord = <Value>(
  record: Readonly<Record<string, Value>>,
): Record<string, Value> =>
  Object.fromEntries(
    Object.entries(record).sort(([left], [right]) =>
      left.localeCompare(right),
    ),
  )

/**
 * Keeps generated documents stable for checked-in manifests and diffs while
 * preserving array order and all operation-level semantics.
 */
export const normalizeOpenApiSpec = (
  spec: OpenApi.OpenAPISpec,
): OpenApi.OpenAPISpec => ({
  ...spec,
  paths: sortRecord(spec.paths),
  components: {
    ...spec.components,
    schemas: sortRecord(spec.components.schemas),
    securitySchemes: sortRecord(spec.components.securitySchemes),
  },
})

export const makeOpenApiDocumentLayer = <
  Id extends string,
  Groups extends HttpApiGroup.Constraint,
>(
  definition: OpenApiDocumentDefinition<Id, Groups>,
) => {
  const spec = normalizeOpenApiSpec(OpenApi.fromApi(definition.api))
  const jsonResponse = HttpServerResponse.jsonUnsafe(spec, {
    headers: {
      "cache-control": "no-store",
    },
  })

  return Layer.mergeAll(
    HttpRouter.add("GET", definition.jsonPath, jsonResponse),
    HttpApiSwagger.layer(definition.api, {
      path: definition.swaggerPath,
    }),
  )
}
