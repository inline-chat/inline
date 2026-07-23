export type MediaByteRange = {
  start: number
  end: number
  length: number
}

export type MediaRangeResult =
  | { kind: "full" }
  | { kind: "partial"; range: MediaByteRange }
  | { kind: "unsatisfiable" }

const decimalByteOffset = /^\d+$/

const parseOffset = (value: string) => {
  if (!decimalByteOffset.test(value)) return undefined
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) ? parsed : undefined
}

/** Parses the single byte range used by browser media elements. Multipart
 * ranges are deliberately refused: Inline serves one bounded R2 slice per
 * request and never assembles multipart/byteranges responses in memory. */
export const parseMediaRange = (
  header: string | null | undefined,
  totalSize: number,
): MediaRangeResult => {
  if (!header) return { kind: "full" }
  if (!Number.isSafeInteger(totalSize) || totalSize <= 0) {
    return { kind: "unsatisfiable" }
  }

  const match = /^bytes=([^,]+)$/i.exec(header.trim())
  if (!match) return { kind: "unsatisfiable" }
  const specification = match[1]?.trim()
  if (!specification) return { kind: "unsatisfiable" }

  const separator = specification.indexOf("-")
  if (separator < 0 || specification.indexOf("-", separator + 1) >= 0) {
    return { kind: "unsatisfiable" }
  }

  const startText = specification.slice(0, separator)
  const endText = specification.slice(separator + 1)
  let start: number
  let end: number

  if (startText === "") {
    const suffixLength = parseOffset(endText)
    if (suffixLength === undefined || suffixLength <= 0) {
      return { kind: "unsatisfiable" }
    }
    const boundedLength = Math.min(suffixLength, totalSize)
    start = totalSize - boundedLength
    end = totalSize - 1
  } else {
    const parsedStart = parseOffset(startText)
    if (parsedStart === undefined || parsedStart >= totalSize) {
      return { kind: "unsatisfiable" }
    }
    start = parsedStart
    if (endText === "") {
      end = totalSize - 1
    } else {
      const parsedEnd = parseOffset(endText)
      if (parsedEnd === undefined || parsedEnd < start) {
        return { kind: "unsatisfiable" }
      }
      end = Math.min(parsedEnd, totalSize - 1)
    }
  }

  return {
    kind: "partial",
    range: {
      start,
      end,
      length: end - start + 1,
    },
  }
}

export const mediaEntityTag = (
  fileUniqueId: string,
  totalSize: number,
) => `"${fileUniqueId}-${totalSize}"`

const entityTags = (value: string) =>
  value.split(",").map((tag) => tag.trim())

export const mediaEntityTagMatches = (
  header: string | null | undefined,
  entityTag: string,
) => Boolean(
  header &&
  entityTags(header).some(
    (candidate) => candidate === "*" || candidate === entityTag,
  ),
)

export const mediaIfRangeMatches = (
  header: string | null | undefined,
  entityTag: string,
) => !header || header.trim() === entityTag
