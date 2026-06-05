import { DEFAULT_MAX_REDIRECTS, DEFAULT_TIMEOUT_MS, DEFAULT_USER_AGENT } from "./constants.js"
import { baseContentType, defaultLookup, fetchByteRange } from "./network.js"
import type { FetchUrlPreviewOptions } from "./types.js"

const firstRangeBytes = 256 * 1024
const tailRangeBytes = 4 * 1024 * 1024
const metadataTimeoutMs = 3_000
const maxSafeUint64High = Math.floor(Number.MAX_SAFE_INTEGER / 0x1_0000_0000)

export type VideoMetadata = {
  duration?: number
}

export async function fetchVideoMetadata(
  url: string,
  contentType: string,
  options: FetchUrlPreviewOptions,
): Promise<VideoMetadata | null> {
  const base = baseContentType(contentType)
  if (!isMp4LikeContentType(base)) {
    return null
  }

  const timeoutMs = Math.min(options.timeoutMs ?? DEFAULT_TIMEOUT_MS, metadataTimeoutMs)
  const rangeOptions = {
    fetchImpl: options.fetchImpl,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: base,
  }

  const first = await fetchByteRange(url, `bytes=0-${firstRangeBytes - 1}`, {
    ...rangeOptions,
    maxBytes: firstRangeBytes,
  }).catch(() => null)
  const firstDuration = parseMp4Duration(first?.bytes)
  if (firstDuration != null) {
    return { duration: firstDuration }
  }

  const tail = await fetchByteRange(url, `bytes=-${tailRangeBytes}`, {
    ...rangeOptions,
    maxBytes: tailRangeBytes,
  }).catch(() => null)
  const tailDuration = parseMp4Duration(tail?.bytes)
  return tailDuration == null ? null : { duration: tailDuration }
}

function isMp4LikeContentType(contentType: string): boolean {
  return (
    contentType === "video/mp4" ||
    contentType === "video/quicktime" ||
    contentType === "video/x-m4v" ||
    contentType === "application/mp4"
  )
}

function parseMp4Duration(bytes: Uint8Array | undefined): number | undefined {
  if (!bytes || bytes.length < 32) {
    return undefined
  }

  for (let typeOffset = 4; typeOffset <= bytes.length - 4; typeOffset += 1) {
    if (!matchesBoxType(bytes, typeOffset, "mvhd")) {
      continue
    }

    const duration = parseMvhdDuration(bytes, typeOffset - 4)
    if (duration != null) {
      return duration
    }
  }

  return undefined
}

function parseMvhdDuration(bytes: Uint8Array, boxStart: number): number | undefined {
  const size = readUint32(bytes, boxStart)
  if (size == null || size < 32) {
    return undefined
  }

  const boxEnd = boxStart + size
  if (boxEnd > bytes.length) {
    return undefined
  }

  const payloadStart = boxStart + 8
  const version = bytes[payloadStart]
  if (version === 0) {
    return durationSeconds(
      readUint32(bytes, payloadStart + 12),
      readUint32(bytes, payloadStart + 16),
    )
  }

  if (version === 1) {
    return durationSeconds(
      readUint32(bytes, payloadStart + 20),
      readUint64(bytes, payloadStart + 24),
    )
  }

  return undefined
}

function durationSeconds(timescale: number | undefined, duration: number | undefined): number | undefined {
  if (!timescale || !duration) {
    return undefined
  }

  const seconds = Math.round(duration / timescale)
  return Number.isFinite(seconds) && seconds > 0 ? seconds : undefined
}

function matchesBoxType(bytes: Uint8Array, offset: number, type: string): boolean {
  return (
    bytes[offset] === type.charCodeAt(0) &&
    bytes[offset + 1] === type.charCodeAt(1) &&
    bytes[offset + 2] === type.charCodeAt(2) &&
    bytes[offset + 3] === type.charCodeAt(3)
  )
}

function readUint32(bytes: Uint8Array, offset: number): number | undefined {
  if (offset < 0 || offset + 4 > bytes.length) {
    return undefined
  }

  return ((bytes[offset]! << 24) | (bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!) >>> 0
}

function readUint64(bytes: Uint8Array, offset: number): number | undefined {
  const high = readUint32(bytes, offset)
  const low = readUint32(bytes, offset + 4)
  if (high == null || low == null || high > maxSafeUint64High) {
    return undefined
  }

  return high * 0x1_0000_0000 + low
}
