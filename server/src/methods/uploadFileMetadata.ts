import { ApiError, InlineError } from "@in/server/types/errors"

export interface UploadFileMetadataInput {
  readonly type: "photo" | "video" | "document" | "voice"
  readonly width?: string | null | undefined
  readonly height?: string | null | undefined
  readonly duration?: string | null | undefined
  readonly isAnimated?: string | null | undefined
  readonly hasAudio?: string | null | undefined
  readonly waveform?: string | null | undefined
}

export interface ValidatedUploadFileMetadata {
  readonly width: number | undefined
  readonly height: number | undefined
  readonly duration: number | undefined
  readonly isAnimated: boolean | undefined
  readonly hasAudio: boolean | undefined
  readonly waveform: Uint8Array | undefined
}

const badRequest = (description: string): InlineError => {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}

const parseOptionalInt = (
  name: string,
  value: string | null | undefined,
  min: number,
): number | undefined => {
  if (value == null) return undefined
  const trimmed = value.trim()
  if (!trimmed) {
    throw badRequest(`Invalid ${name}: expected a number`)
  }

  const parsed = Number(trimmed)
  if (!Number.isInteger(parsed) || parsed < min) {
    throw badRequest(`Invalid ${name}: expected integer >= ${min}`)
  }
  return parsed
}

const parseOptionalBool = (
  name: string,
  value: string | null | undefined,
): boolean | undefined => {
  if (value == null) return undefined
  const trimmed = value.trim().toLowerCase()
  if (trimmed === "true" || trimmed === "1") return true
  if (trimmed === "false" || trimmed === "0") return false
  throw badRequest(`Invalid ${name}: expected true or false`)
}

const parseRequiredBase64 = (
  name: string,
  value: string | null | undefined,
): Uint8Array | undefined => {
  if (value == null) return undefined
  const compact = value.trim().replace(/\s+/g, "")
  if (
    compact === "" ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(compact) ||
    compact.length % 4 !== 0
  ) {
    throw badRequest(`Invalid ${name}: expected base64 data`)
  }
  return Uint8Array.from(Buffer.from(compact, "base64"))
}

export const validateUploadFileMetadata = (
  input: UploadFileMetadataInput,
): ValidatedUploadFileMetadata => {
  const width = input.type === "video"
    ? parseOptionalInt("width", input.width, 1)
    : undefined
  const height = input.type === "video"
    ? parseOptionalInt("height", input.height, 1)
    : undefined
  const duration = input.type === "video" || input.type === "voice"
    ? parseOptionalInt("duration", input.duration, 0)
    : undefined
  const isAnimated = input.type === "video"
    ? parseOptionalBool("isAnimated", input.isAnimated)
    : undefined
  const hasAudio = input.type === "video"
    ? parseOptionalBool("hasAudio", input.hasAudio)
    : undefined
  const waveform = input.type === "voice"
    ? parseRequiredBase64("waveform", input.waveform)
    : undefined

  if (
    input.type === "video" &&
    (width === undefined || height === undefined || duration === undefined)
  ) {
    throw badRequest("Video upload requires width, height, and duration")
  }
  if (input.type === "video" && isAnimated === true && hasAudio === true) {
    throw badRequest("Animated video uploads must be silent")
  }
  if (
    input.type !== "video" &&
    (input.isAnimated !== undefined || input.hasAudio !== undefined)
  ) {
    throw badRequest(
      "Animated/audio video metadata is only valid for video uploads",
    )
  }
  if (
    input.type === "voice" &&
    (duration === undefined || waveform === undefined)
  ) {
    throw badRequest("Voice upload requires duration and waveform")
  }

  return {
    width,
    height,
    duration,
    isAnimated,
    hasAudio,
    waveform,
  }
}
