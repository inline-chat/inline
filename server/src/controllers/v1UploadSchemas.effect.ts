import { Schema } from "effect"
import { Multipart } from "effect/unstable/http"
import { HttpApiSchema } from "effect/unstable/httpapi"
import { WirePositiveInteger } from "../core/schema/scalars"

export const UploadFileType = Schema.Literals(["photo", "video", "document", "voice"]).annotate({
  identifier: "UploadFileType",
})

const UploadMetadata = {
  width: Schema.optionalKey(Schema.String),
  height: Schema.optionalKey(Schema.String),
  duration: Schema.optionalKey(Schema.String),
  isAnimated: Schema.optionalKey(Schema.String),
  hasAudio: Schema.optionalKey(Schema.String),
  waveform: Schema.optionalKey(Schema.String),
} as const

/** Buffered multipart contract used for OpenAPI generation. */
export const UploadFilePayload = Schema.Struct({
  type: UploadFileType,
  file: Multipart.SingleFileSchema,
  // TODO(effect-upgrade): Re-check `optionalKey` when the pinned Effect beta
  // fixes transformed SingleFileSchema optionality in generated OpenAPI.
  thumbnail: Schema.optional(Multipart.SingleFileSchema),
  ...UploadMetadata,
})
  .pipe(HttpApiSchema.asMultipart())
  .annotate({ identifier: "UploadFilePayload" })

/** Web request view passed to the existing Bun upload implementation. */
export const UploadFileInput = Schema.Struct({
  type: UploadFileType,
  file: Schema.instanceOf(File),
  thumbnail: Schema.optionalKey(Schema.instanceOf(File)),
  ...UploadMetadata,
}).annotate({ identifier: "UploadFileInput" })
export type UploadFileInput = typeof UploadFileInput.Type

export const UploadFileResult = Schema.Struct({
  fileUniqueId: Schema.String,
  photoId: Schema.optionalKey(WirePositiveInteger),
  videoId: Schema.optionalKey(WirePositiveInteger),
  documentId: Schema.optionalKey(WirePositiveInteger),
  voiceId: Schema.optionalKey(WirePositiveInteger),
}).annotate({ identifier: "UploadFileResult" })
export type UploadFileResult = typeof UploadFileResult.Type
