import {
  Context,
  Data,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
} from "effect/unstable/httpapi"
import {
  AuxiliaryInternalServerError,
  AuxiliaryRequestParsingFailure,
  LegacyValidationError,
  decodeLegacyStringObject,
  queryRecord,
} from "./auxiliaryValidation.effect"

export const MediaPhotoQuery = Schema.Struct({
  id: Schema.String,
  exp: Schema.String,
  sig: Schema.String,
}).annotate({
  identifier: "MediaPhotoQuery",
})

export type MediaPhotoQuery = typeof MediaPhotoQuery.Type

const MediaForbidden = Schema.Literal(
  "forbidden",
).pipe(
  HttpApiSchema.status(403),
  HttpApiSchema.asText(),
).annotate({
  identifier: "MediaForbidden",
})

const MediaNotFound = Schema.Literal(
  "not_found",
).pipe(
  HttpApiSchema.status(404),
  HttpApiSchema.asText(),
).annotate({
  identifier: "MediaNotFound",
})

const MediaStorageUnavailable = Schema.Literal(
  "storage_unavailable",
).pipe(
  HttpApiSchema.status(503),
  HttpApiSchema.asText(),
).annotate({
  identifier: "MediaStorageUnavailable",
})

const MediaPhotoStream =
  HttpApiSchema.StreamUint8Array({
    contentType: "image/*",
  })

export const MediaEndpoints = {
  photo: HttpApiEndpoint.get(
    "mediaPhoto",
    "/file",
    {
      payload: MediaPhotoQuery.fields,
      success: MediaPhotoStream,
      error: [
        LegacyValidationError,
        MediaForbidden,
        MediaNotFound,
        MediaStorageUnavailable,
        AuxiliaryInternalServerError,
      ],
    },
  ),
} as const

export interface MediaFileRecord {
  readonly fileType: string | null
  readonly pathEncrypted: Buffer | null
  readonly pathIv: Buffer | null
  readonly pathTag: Buffer | null
  readonly mimeType: string | null
}

export interface MediaBucketFile {
  readonly exists: () => Promise<boolean>
  readonly stream: () => ReadableStream<Uint8Array>
}

export type MediaOperation =
  | "signature"
  | "lookup"
  | "storage"

export class MediaOperationFailure extends Data.TaggedError(
  "MediaOperationFailure",
)<{
  readonly operation: MediaOperation
  readonly cause: unknown
}> {}

export interface MediaOperationsShape {
  readonly servePhoto: (
    query: MediaPhotoQuery,
  ) => Effect.Effect<Response, MediaOperationFailure>
}

export class MediaOperations extends Context.Service<
  MediaOperations,
  MediaOperationsShape
>()("@inline/server/auxiliary/MediaOperations") {}

export interface MediaOperationDependencies {
  readonly filesPathPrefix: string
  readonly verify: (input: {
    readonly fileUniqueId: string
    readonly exp: number
    readonly sig: string
  }) => boolean
  readonly lookup: (
    fileUniqueId: string,
  ) => Promise<MediaFileRecord | undefined>
  readonly decryptPath: (input: {
    readonly encrypted: Buffer
    readonly iv: Buffer
    readonly authTag: Buffer
  }) => string
  readonly getObject: (
    path: string,
  ) => MediaBucketFile | undefined
  readonly nowSeconds: () => number
}

const textResponse = (
  status: number,
  body: string,
): Response =>
  new Response(
    new TextEncoder().encode(body),
    { status },
  )

const resolvePath = (
  file: MediaFileRecord,
  decryptPath: MediaOperationDependencies["decryptPath"],
): string | null => {
  if (
    file.pathEncrypted === null ||
    file.pathIv === null ||
    file.pathTag === null
  ) {
    return null
  }

  try {
    return decryptPath({
      encrypted: file.pathEncrypted,
      iv: file.pathIv,
      authTag: file.pathTag,
    })
  } catch {
    return null
  }
}

export const makeMediaOperations = ({
  filesPathPrefix,
  verify,
  lookup,
  decryptPath,
  getObject,
  nowSeconds,
}: MediaOperationDependencies): MediaOperationsShape => ({
  servePhoto: (query) => {
    const exp = Number.parseInt(query.exp, 10)
    return Effect.try({
      try: () =>
        verify({
          fileUniqueId: query.id,
          exp,
          sig: query.sig,
        }),
      catch: (cause) =>
        new MediaOperationFailure({
          operation: "signature",
          cause,
        }),
    }).pipe(
      Effect.flatMap((verified) => {
        if (!verified) {
          return Effect.succeed(
            textResponse(403, "forbidden"),
          )
        }

        return Effect.tryPromise({
          try: () => lookup(query.id),
          catch: (cause) =>
            new MediaOperationFailure({
              operation: "lookup",
              cause,
            }),
        }).pipe(
          Effect.flatMap((file) => {
            if (
              file === undefined ||
              file.fileType !== "photo"
            ) {
              return Effect.succeed(
                textResponse(404, "not_found"),
              )
            }

            const path = resolvePath(
              file,
              decryptPath,
            )
            if (path === null) {
              return Effect.succeed(
                textResponse(404, "not_found"),
              )
            }

            return Effect.try({
              try: () =>
                getObject(
                  `${filesPathPrefix}/${path}`,
                ),
              catch: (cause) =>
                new MediaOperationFailure({
                  operation: "storage",
                  cause,
                }),
            }).pipe(
              Effect.flatMap((object) => {
                if (object === undefined) {
                  return Effect.succeed(
                    textResponse(
                      503,
                      "storage_unavailable",
                    ),
                  )
                }

                return Effect.tryPromise({
                  try: () => object.exists(),
                  catch: (cause) =>
                    new MediaOperationFailure({
                      operation: "storage",
                      cause,
                    }),
                }).pipe(
                  Effect.flatMap((exists) => {
                    if (!exists) {
                      return Effect.succeed(
                        textResponse(
                          404,
                          "not_found",
                        ),
                      )
                    }

                    return Effect.try({
                      try: () => {
                        const maxAge = Math.max(
                          0,
                          Math.min(
                            exp - nowSeconds(),
                            3_600,
                          ),
                        )

                        return new Response(
                          object.stream(),
                          {
                            headers: {
                              "content-type":
                                file.mimeType ??
                                "image/jpeg",
                              "cache-control":
                                `public, max-age=${maxAge}`,
                              "x-content-type-options":
                                "nosniff",
                            },
                          },
                        )
                      },
                      catch: (cause) =>
                        new MediaOperationFailure({
                          operation: "storage",
                          cause,
                        }),
                    })
                  }),
                )
              }),
            )
          }),
        )
      }),
    )
  },
})

const mediaQueryFields = [
  { name: "id", required: true },
  { name: "exp", required: true },
  { name: "sig", required: true },
] as const

const webResponseToEffect = (
  response: Response,
): HttpServerResponse.HttpServerResponse => {
  const options = {
    status: response.status,
    statusText: response.statusText,
    headers: Object.fromEntries(response.headers),
  }

  return response.body === null
    ? HttpServerResponse.empty(options)
    : HttpServerResponse.raw(response.body, options)
}

export const executeMediaPhoto = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const webRequest =
      yield* HttpServerRequest.toWeb(request).pipe(
        Effect.mapError(
          (cause) =>
            new AuxiliaryRequestParsingFailure({
              cause,
            }),
        ),
      )
    const query = yield* decodeLegacyStringObject(
      MediaPhotoQuery,
      "query",
      queryRecord(webRequest),
      mediaQueryFields,
    )
    const operations = yield* MediaOperations
    const response =
      yield* operations.servePhoto(query)
    return webResponseToEffect(response)
  })
