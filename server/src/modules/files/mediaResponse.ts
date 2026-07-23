import {
  mediaEntityTag,
  mediaEntityTagMatches,
  mediaIfRangeMatches,
  parseMediaRange,
} from "./mediaRange"

export interface MediaRangeReadableFile {
  readonly stream: () => ReadableStream<Uint8Array>
  readonly slice: (
    start: number,
    end: number,
    contentType?: string,
  ) => Pick<MediaRangeReadableFile, "stream">
}

export interface MediaRequestHeaders {
  readonly range?: string
  readonly ifRange?: string
  readonly ifNoneMatch?: string
}

const supportedFileTypes = new Set([
  "photo",
  "video",
  "document",
  "voice",
])

export const isSupportedMediaFileType = (
  fileType: string | null,
) => fileType !== null && supportedFileTypes.has(fileType)

export const createMediaFileResponse = ({
  object,
  fileUniqueId,
  fileSize,
  mimeType,
  maxAge,
  requestHeaders,
  forceDownload = false,
}: {
  object: MediaRangeReadableFile
  fileUniqueId: string
  fileSize: number | null
  mimeType: string | null
  maxAge: number
  requestHeaders: MediaRequestHeaders
  forceDownload?: boolean
}) => {
  const contentType =
    mimeType?.trim() || "application/octet-stream"
  const safetyHeaders: Record<string, string> = forceDownload
    ? {
        "content-disposition": "attachment",
        "content-security-policy":
          "sandbox; default-src 'none'",
      }
    : {}

  if (
    fileSize === null ||
    !Number.isSafeInteger(fileSize) ||
    fileSize <= 0
  ) {
    // The legacy photo proxy streamed records before fileSize became a
    // reliable invariant. Keep those existing URLs usable, but do not claim
    // range or validator support without trustworthy representation length.
    return new Response(object.stream(), {
      headers: {
        "cache-control": `public, max-age=${maxAge}`,
        "content-type": contentType,
        "x-content-type-options": "nosniff",
        ...safetyHeaders,
      },
    })
  }

  const entityTag = mediaEntityTag(
    fileUniqueId,
    fileSize,
  )
  const commonHeaders = {
    "accept-ranges": "bytes",
    "cache-control": `public, max-age=${maxAge}`,
    etag: entityTag,
    "x-content-type-options": "nosniff",
    ...safetyHeaders,
  }

  if (
    mediaEntityTagMatches(
      requestHeaders.ifNoneMatch,
      entityTag,
    )
  ) {
    return new Response(null, {
      status: 304,
      headers: commonHeaders,
    })
  }

  const range = mediaIfRangeMatches(
    requestHeaders.ifRange,
    entityTag,
  )
    ? parseMediaRange(
        requestHeaders.range,
        fileSize,
      )
    : { kind: "full" as const }

  if (range.kind === "unsatisfiable") {
    return new Response("range_not_satisfiable", {
      status: 416,
      headers: {
        ...commonHeaders,
        "content-range": `bytes */${fileSize}`,
        "content-type": "text/plain; charset=utf-8",
      },
    })
  }

  if (range.kind === "partial") {
    const { start, end, length } = range.range
    return new Response(
      object
        .slice(start, end + 1, contentType)
        .stream(),
      {
        status: 206,
        statusText: "Partial Content",
        headers: {
          ...commonHeaders,
          "content-length": String(length),
          "content-range":
            `bytes ${start}-${end}/${fileSize}`,
          "content-type": contentType,
        },
      },
    )
  }

  return new Response(object.stream(), {
    headers: {
      ...commonHeaders,
      "content-length": String(fileSize),
      "content-type": contentType,
    },
  })
}
