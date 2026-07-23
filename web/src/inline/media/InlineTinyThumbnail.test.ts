import { describe, expect, it } from "vitest"
import {
  decodeInlineTinyThumbnailJPEG,
  inlineTinyThumbnailDataUrl,
} from "./InlineTinyThumbnail"

describe("InlineTinyThumbnail", () => {
  it("rejects malformed stripped thumbnail payloads", () => {
    expect(decodeInlineTinyThumbnailJPEG()).toBeUndefined()
    expect(
      decodeInlineTinyThumbnailJPEG(new Uint8Array([2, 30, 40])),
    ).toBeUndefined()
  })

  it("reconstructs Inline's stripped JPEG with protocol dimensions", () => {
    const stripped = new Uint8Array([1, 30, 40, 0x11, 0x22])
    const jpeg = decodeInlineTinyThumbnailJPEG(stripped)

    expect(jpeg?.slice(0, 2)).toEqual(new Uint8Array([0xff, 0xd8]))
    expect(jpeg?.slice(-2)).toEqual(new Uint8Array([0xff, 0xd9]))
    expect(jpeg?.[145]).toBe(0)
    expect(jpeg?.[146]).toBe(30)
    expect(jpeg?.[147]).toBe(0)
    expect(jpeg?.[148]).toBe(40)
    expect(inlineTinyThumbnailDataUrl(stripped)).toMatch(
      /^data:image\/jpeg;base64,/,
    )
  })
})
