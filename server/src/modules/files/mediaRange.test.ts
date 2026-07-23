import { describe, expect, it } from "bun:test"
import {
  mediaEntityTag,
  mediaEntityTagMatches,
  mediaIfRangeMatches,
  parseMediaRange,
} from "./mediaRange"

describe("parseMediaRange", () => {
  it("keeps requests without Range on the full representation", () => {
    expect(parseMediaRange(undefined, 100)).toEqual({ kind: "full" })
  })

  it("parses bounded, open-ended, and suffix byte ranges", () => {
    expect(parseMediaRange("bytes=10-19", 100)).toEqual({
      kind: "partial",
      range: { start: 10, end: 19, length: 10 },
    })
    expect(parseMediaRange("bytes=90-", 100)).toEqual({
      kind: "partial",
      range: { start: 90, end: 99, length: 10 },
    })
    expect(parseMediaRange("bytes=-8", 100)).toEqual({
      kind: "partial",
      range: { start: 92, end: 99, length: 8 },
    })
  })

  it("clamps an end and suffix to the immutable representation", () => {
    expect(parseMediaRange("bytes=95-999", 100)).toEqual({
      kind: "partial",
      range: { start: 95, end: 99, length: 5 },
    })
    expect(parseMediaRange("bytes=-999", 100)).toEqual({
      kind: "partial",
      range: { start: 0, end: 99, length: 100 },
    })
  })

  it("refuses malformed, multipart, reversed, and out-of-bounds ranges", () => {
    for (const range of [
      "items=0-1",
      "bytes=0-1,4-5",
      "bytes=ten-20",
      "bytes=20-10",
      "bytes=100-",
      "bytes=-0",
      "bytes=--",
    ]) {
      expect(parseMediaRange(range, 100)).toEqual({
        kind: "unsatisfiable",
      })
    }
  })
})

describe("media validators", () => {
  const entityTag = mediaEntityTag("INVstableFileId", 100)

  it("uses immutable file identity and size", () => {
    expect(entityTag).toBe('"INVstableFileId-100"')
    expect(mediaEntityTagMatches(entityTag, entityTag)).toBe(true)
    expect(mediaEntityTagMatches(`"other", ${entityTag}`, entityTag)).toBe(true)
    expect(mediaEntityTagMatches("*", entityTag)).toBe(true)
  })

  it("requires an exact entity tag for If-Range", () => {
    expect(mediaIfRangeMatches(undefined, entityTag)).toBe(true)
    expect(mediaIfRangeMatches(entityTag, entityTag)).toBe(true)
    expect(mediaIfRangeMatches('W/"INVstableFileId-100"', entityTag)).toBe(false)
    expect(mediaIfRangeMatches("Wed, 21 Oct 2015 07:28:00 GMT", entityTag)).toBe(false)
  })
})
