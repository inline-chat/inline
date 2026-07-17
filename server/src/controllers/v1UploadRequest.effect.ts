import { Effect, Stream } from "effect"
import {
  HttpServerRequest,
  Multipart,
} from "effect/unstable/http"
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
const fileFields = new Set(["file", "thumbnail"])
// TODO(effect-cutover): Source this from a typed, environment-free upload
// configuration service shared by the legacy compatibility adapter.
const maxLegacyUploadFileSize = 500 * 1024 * 1024
const multipartChunkSize = 16 * 1024

export interface V1UploadLimits {
  readonly maxFieldSize: number
  readonly maxFileSize: number
  readonly maxParts: number
  readonly maxTotalSize: number
}

export const defaultV1UploadLimits: V1UploadLimits = {
  maxFieldSize: 64 * 1024,
  maxFileSize: maxLegacyUploadFileSize,
  maxParts: metadataFields.size + fileFields.size,
  // Both the primary file and optional thumbnail retain the current per-file
  // limit. The parser still bounds aggregate buffering before either is exposed.
  maxTotalSize: maxLegacyUploadFileSize * fileFields.size + 1024 * 1024,
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
    description: "The file exceeds the maximum size of 40MB",
  })

const append = (
  result: Record<string, unknown>,
  key: string,
  value: string | File,
) =>
  result[key] !== undefined
    ? Effect.fail(uploadValidationError())
    : Effect.sync(() => {
        result[key] = value
        return result
      })

const mapMultipartFailure = (
  cause: Multipart.MultipartError,
): V1MessagingProvidersPublicError | V1MessagingProvidersRequestFailure => {
  switch (cause.reason._tag) {
    case "BodyTooLarge":
    case "FileTooLarge":
      return uploadTooLargeError()
    case "FieldTooLarge":
    case "TooManyParts":
      return uploadValidationError()
    case "InternalError":
    case "Parse":
      return new V1MessagingProvidersRequestFailure({
        operation: "v1.uploadFile.multipart",
        cause,
      })
  }
}

const validateContentLength = (
  request: HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits,
) => {
  const raw = request.headers["content-length"]
  if (raw === undefined) {
    return Effect.void
  }
  const length = Number(raw)
  if (!Number.isSafeInteger(length) || length < 0) {
    return Effect.fail(uploadValidationError())
  }
  return length > limits.maxTotalSize
    ? Effect.fail(uploadTooLargeError())
    : Effect.void
}

const rechunk = (bytes: Uint8Array): ReadonlyArray<Uint8Array> => {
  const chunks: Array<Uint8Array> = []
  for (let offset = 0; offset < bytes.length; offset += multipartChunkSize) {
    chunks.push(bytes.subarray(offset, offset + multipartChunkSize))
  }
  return chunks
}

const multipartStream = (request: HttpServerRequest.HttpServerRequest) =>
  request.stream.pipe(
    Stream.mapError((cause) =>
      Multipart.MultipartError.fromReason("InternalError", cause),
    ),
    Stream.flatMap((bytes) => Stream.fromIterable(rechunk(bytes))),
    Stream.pipeThroughChannel(Multipart.makeChannel(request.headers)),
  )

const collectFile = (
  file: Multipart.File,
  maxFileSize: number,
) =>
  // TODO(effect-cutover): pipe validated chunks directly to an Effect-native
  // storage capability instead of assembling a compatibility File in memory.
  file.content.pipe(
    Stream.runFoldEffect(
      () => ({
        chunks: [] as Array<Uint8Array>,
        size: 0,
      }),
      (state, chunk) => {
        const size = state.size + chunk.length
        if (size > maxFileSize) {
          return Effect.fail(uploadTooLargeError())
        }
        state.chunks.push(chunk)
        return Effect.succeed({
          chunks: state.chunks,
          size,
        })
      },
    ),
    Effect.map(({ chunks, size }) => {
      const content = new Uint8Array(size)
      let offset = 0
      for (const chunk of chunks) {
        content.set(chunk, offset)
        offset += chunk.length
      }
      return content
    }),
    Effect.mapError((cause) =>
      cause instanceof V1MessagingProvidersPublicError
        ? cause
        : mapMultipartFailure(cause),
    ),
  )

/**
 * Parses upload multipart as a bounded stream before authentication.
 *
 * Content-Length is only an early rejection hint. Requests without it
 * (including chunked bodies) remain bounded by the parser's total, file,
 * field, and part-count limits.
 */
export const parseV1UploadRequest = (
  request: HttpServerRequest.HttpServerRequest,
  limits: V1UploadLimits = defaultV1UploadLimits,
) =>
  validateContentLength(request, limits).pipe(
    Effect.andThen(
      multipartStream(request).pipe(
        Stream.runFoldEffect(
          () => ({} as Record<string, unknown>),
          (result, part) => {
            if (Multipart.isField(part)) {
              if (
                new TextEncoder().encode(part.value).length >
                limits.maxFieldSize
              ) {
                return Effect.fail(uploadValidationError())
              }
              return metadataFields.has(part.key)
                ? append(result, part.key, part.value)
                : Effect.fail(uploadValidationError())
            }

            if (!fileFields.has(part.key)) {
              return Effect.fail(uploadValidationError())
            }

            return collectFile(part, limits.maxFileSize).pipe(
              Effect.flatMap((content) => {
                const bytes = new Uint8Array(content.length)
                bytes.set(content)
                return append(
                  result,
                  part.key,
                  new File([bytes.buffer], part.name, {
                    type: part.contentType,
                  }),
                )
              }),
            )
          },
        ),
        Effect.provideContext(
          Multipart.limitsServices({
            maxFieldSize: limits.maxFieldSize,
            maxFileSize: limits.maxFileSize,
            maxParts: limits.maxParts,
            maxTotalSize: limits.maxTotalSize,
          }),
        ),
        Effect.mapError((cause) =>
          cause instanceof V1MessagingProvidersPublicError ||
            cause instanceof V1MessagingProvidersRequestFailure
            ? cause
            : mapMultipartFailure(cause),
        ),
      ),
    ),
  )
