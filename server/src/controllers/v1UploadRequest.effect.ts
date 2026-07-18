import {
  Effect,
  FileSystem,
  Path,
  Stream,
} from "effect"
import {
  HttpServerRequest,
  Multipart,
} from "effect/unstable/http"
import {
  openAsBlob,
} from "node:fs"
import {
  V1MessagingProvidersPublicError,
  V1MessagingProvidersRequestFailure,
} from "./v1MessagingProvidersErrors.effect"

const metadataFields = new Set([
  "duration",
  "hasAudio",
  "height",
  "isAnimated",
  "type",
  "waveform",
  "width",
])
const fileFields = new Set([
  "file",
  "thumbnail",
])
// TODO(effect-cutover): Source this from a typed, environment-free upload
// configuration service shared by the legacy compatibility adapter.
const maxAcceptedMainFileSize =
  200_000_000
const maxAcceptedPhotoFileSize =
  40_000_000
const maxAcceptedThumbnailFileSize =
  40_000_000
const maxAcceptedVoiceFileSize =
  20_000_000
const multipartChunkSize =
  16 * 1024

export interface V1UploadLimits {
  readonly maxFieldSize: number
  readonly maxFileSize: number
  readonly maxThumbnailFileSize: number
  readonly maxParts: number
  readonly maxTotalSize: number
}

export const defaultV1UploadLimits: V1UploadLimits = {
  maxFieldSize: 64 * 1024,
  maxFileSize: maxAcceptedMainFileSize,
  maxThumbnailFileSize:
    maxAcceptedThumbnailFileSize,
  maxParts:
    metadataFields.size + fileFields.size,
  // No successful retained operation accepts more than a 200 MB main file or
  // 40 MB thumbnail. The extra 1 MB covers multipart fields and boundaries.
  maxTotalSize:
    maxAcceptedMainFileSize +
    maxAcceptedThumbnailFileSize +
    1_000_000,
}

const uploadValidationError = () =>
  new V1MessagingProvidersPublicError({
    error: "INVALID_ARGS",
    errorCode: 400,
    description: "Validation error",
  })

const uploadTooLargeError = () =>
  new V1MessagingProvidersPublicError({
    error: "FILE_TOO_LARGE",
    errorCode: 400,
    // FIXME(effect-cutover): Correct this stale 40MB description once the
    // public compatibility envelope can change independently of this parser.
    description:
      "The file exceeds the maximum size of 40MB",
  })

const mapMultipartFailure = (
  cause: Multipart.MultipartError,
):
  | V1MessagingProvidersPublicError
  | V1MessagingProvidersRequestFailure => {
  switch (cause.reason._tag) {
    case "BodyTooLarge":
    case "FileTooLarge":
      return uploadTooLargeError()
    case "FieldTooLarge":
    case "Parse":
    case "TooManyParts":
      return uploadValidationError()
    case "InternalError":
      return new V1MessagingProvidersRequestFailure({
        operation:
          "v1.uploadFile.multipart",
        cause,
      })
  }
}

const validateContentLength = (
  request:
    HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits,
) => {
  const raw =
    request.headers["content-length"]
  if (raw === undefined) {
    return Effect.void
  }
  const length = Number(raw)
  if (
    !Number.isSafeInteger(length) ||
    length < 0
  ) {
    return Effect.fail(
      uploadValidationError(),
    )
  }
  return length > limits.maxTotalSize
    ? Effect.fail(uploadTooLargeError())
    : Effect.void
}

const validateMultipartMediaType = (
  request:
    HttpServerRequest.HttpServerRequest,
) => {
  const contentType =
    request.headers["content-type"]
      ?.trim()
      .toLowerCase()
  return contentType?.startsWith(
    "multipart/form-data;",
  ) === true &&
      contentType.includes("boundary=")
    ? Effect.void
    : Effect.fail(uploadValidationError())
}

/**
 * Rejects unsupported upload transports and impossible declared sizes without
 * consuming the request body. This preserves the legacy 400 for empty/JSON
 * upload requests while allowing authentication to run before multipart I/O.
 */
export const validateV1UploadRequestHeaders = (
  request:
    HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits =
    defaultV1UploadLimits,
) =>
  validateMultipartMediaType(
    request,
  ).pipe(
    Effect.andThen(
      validateContentLength(
        request,
        limits,
      ),
    ),
  )

const rechunk = (
  bytes: Uint8Array,
): ReadonlyArray<Uint8Array> => {
  const chunks:
    Array<Uint8Array> = []
  for (
    let offset = 0;
    offset < bytes.length;
    offset += multipartChunkSize
  ) {
    chunks.push(
      bytes.subarray(
        offset,
        offset + multipartChunkSize,
      ),
    )
  }
  return chunks
}

const boundedMultipartStream = (
  request:
    HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits,
) => {
  let totalSize = 0
  return request.stream.pipe(
    Stream.mapError((cause) =>
      Multipart.MultipartError.fromReason(
        "InternalError",
        cause,
      ),
    ),
    Stream.flatMap((bytes) =>
      Stream.fromIterable(
        rechunk(bytes),
      ),
    ),
    Stream.mapEffect((chunk) => {
      totalSize += chunk.length
      return totalSize >
          limits.maxTotalSize
        ? Effect.fail(
            Multipart.MultipartError
              .fromReason(
                "BodyTooLarge",
              ),
          )
        : Effect.succeed(chunk)
    }),
    Stream.pipeThroughChannel(
      Multipart.makeChannel(
        request.headers,
      ),
    ),
  )
}

const persistFile = (
  maxFileSize: number,
) =>
  (
    path: string,
    file: Multipart.File,
  ) =>
    Effect.gen(function* () {
      const fs =
        yield* FileSystem.FileSystem
      let size = 0
      yield* Stream.run(
        file.content.pipe(
          Stream.mapEffect((chunk) => {
            size += chunk.length
            return size > maxFileSize
              ? Effect.fail(
                  Multipart.MultipartError
                    .fromReason(
                      "FileTooLarge",
                    ),
                )
              : Effect.succeed(chunk)
          }),
        ),
        fs.sink(path),
      ).pipe(
        Effect.catchTag(
          "PlatformError",
          (cause) =>
            Effect.fail(
              Multipart.MultipartError
                .fromReason(
                  "InternalError",
                  cause,
                ),
          ),
        ),
      )
      return size
    })

interface PersistedUploadFile {
  readonly contentType: string
  readonly name: string
  readonly path: string
  readonly size: number
}

const persistedFile = (
  file: PersistedUploadFile,
): Effect.Effect<
  File,
  V1MessagingProvidersRequestFailure
> =>
  Effect.tryPromise({
    try: async () => {
      // Bun.file and Node's openAsBlob both retain a lazy path-backed Blob.
      // Constructing the compatibility File does not materialize the upload.
      const blob =
        typeof Bun === "undefined"
          ? await openAsBlob(file.path, {
              type: file.contentType,
            })
          : Bun.file(file.path, {
              type: file.contentType,
            })
      return new File(
        [blob],
        file.name,
        { type: file.contentType },
      )
    },
    catch: (cause) =>
      new V1MessagingProvidersRequestFailure({
        operation:
          "v1.uploadFile.persisted-file",
        cause,
      }),
  })

const maxMainFileSizeForType = (
  type: unknown,
): number => {
  switch (type) {
    case "photo":
      return maxAcceptedPhotoFileSize
    case "voice":
      return maxAcceptedVoiceFileSize
    default:
      return maxAcceptedMainFileSize
  }
}

const persistMultipartInput = (
  request:
    HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits,
) =>
  Effect.gen(function* () {
    const fs =
      yield* FileSystem.FileSystem
    const path =
      yield* Path.Path
    const directory =
      yield* fs.makeTempDirectoryScoped()
    const persisted:
      Record<
        string,
        string | PersistedUploadFile
      > = Object.create(null)
    let fileIndex = 0

    yield* Stream.runForEach(
      boundedMultipartStream(
        request,
        limits,
      ),
      (part) =>
        Effect.gen(function* () {
          if (Multipart.isField(part)) {
            if (
              !metadataFields.has(part.key) ||
              Object.hasOwn(
                persisted,
                part.key,
              ) ||
              new TextEncoder().encode(
                  part.value,
                ).length >
                limits.maxFieldSize
            ) {
              return yield* Effect.fail(
                uploadValidationError(),
              )
            }
            persisted[part.key] =
              part.value
            return
          }

          if (part.name === "") {
            return
          }
          if (
            !fileFields.has(part.key) ||
            Object.hasOwn(
              persisted,
              part.key,
            )
          ) {
            return yield* Effect.fail(
              uploadValidationError(),
            )
          }
          const key =
            part.key as
              | "file"
              | "thumbnail"
          const safeName =
            path.basename(
              part.name,
            ).slice(-128) || "upload"
          const targetPath =
            path.join(
              directory,
              `${fileIndex}-${safeName}`,
            )
          fileIndex += 1
          const size =
            yield* persistFile(
              key === "thumbnail"
                ? limits
                    .maxThumbnailFileSize
                : limits.maxFileSize,
            )(
              targetPath,
              part,
            )
          persisted[key] = {
            contentType:
              part.contentType,
            name: part.name,
            path: targetPath,
            size,
          }
        }),
    )

    const main = persisted["file"]
    if (
      typeof main !== "string" &&
      main !== undefined &&
      main.size >
        Math.min(
          limits.maxFileSize,
          maxMainFileSizeForType(
            persisted["type"],
          ),
        )
    ) {
      return yield* Effect.fail(
        uploadTooLargeError(),
      )
    }

    const result:
      Record<string, unknown> = {}
    for (
      const [key, value] of
      Object.entries(persisted)
    ) {
      if (typeof value === "string") {
        result[key] = value
      } else {
        result[key] =
          yield* persistedFile(value)
      }
    }
    return result
  }).pipe(
    Effect.provideService(
      Multipart.MaxFieldSize,
      FileSystem.Size(
        limits.maxFieldSize,
      ),
    ),
    Effect.provideService(
      Multipart.MaxFileSize,
      FileSystem.Size(
        limits.maxFileSize,
      ),
    ),
    Effect.provideService(
      Multipart.MaxParts,
      limits.maxParts,
    ),
    Effect.mapError((cause) =>
      cause instanceof
          V1MessagingProvidersPublicError ||
        cause instanceof
          V1MessagingProvidersRequestFailure
        ? cause
        : cause instanceof
            Multipart.MultipartError
          ? mapMultipartFailure(cause)
          : new V1MessagingProvidersRequestFailure({
              operation:
                "v1.uploadFile.temporary-storage",
              cause,
            }),
    ),
  )

/**
 * Persists authenticated multipart files in a request-scoped temporary
 * directory, then exposes lazy disk-backed `File` values to the retained
 * framework-neutral upload operation.
 */
export const parseV1UploadRequest = (
  request:
    HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits =
    defaultV1UploadLimits,
) =>
  Effect.gen(function* () {
    yield* validateV1UploadRequestHeaders(
      request,
      limits,
    )
    return yield* persistMultipartInput(
      request,
      limits,
    )
  })
