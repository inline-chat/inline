import { describe, expect, it } from "bun:test"
import {
  createMediaFileResponse,
  type MediaRangeReadableFile,
} from "./mediaResponse"

const bytes = new Uint8Array([1, 2, 3, 4])

const object: MediaRangeReadableFile = {
  stream: () => new Blob([bytes]).stream(),
  slice: (start, end) => ({
    stream: () =>
      new Blob([bytes.slice(start, end)]).stream(),
  }),
}

describe("createMediaFileResponse", () => {
  it("preserves legacy full streaming when size metadata is unavailable", async () => {
    const response = createMediaFileResponse({
      object,
      fileUniqueId: "INPlegacyPhoto",
      fileSize: null,
      mimeType: "image/jpeg",
      maxAge: 600,
      requestHeaders: { range: "bytes=0-1" },
    })

    expect(response.status).toBe(200)
    expect(response.headers.get("accept-ranges")).toBeNull()
    expect(response.headers.get("content-range")).toBeNull()
    expect(response.headers.get("etag")).toBeNull()
    expect(response.headers.get("content-type")).toBe(
      "image/jpeg",
    )
    expect(Array.from(await response.bytes())).toEqual([
      1,
      2,
      3,
      4,
    ])
  })

  it("forces explicitly proxied documents to download on the API origin", () => {
    const response = createMediaFileResponse({
      object,
      fileUniqueId: "INDactiveDocument",
      fileSize: bytes.length,
      mimeType: "text/html",
      maxAge: 600,
      requestHeaders: {},
      forceDownload: true,
    })

    expect(response.headers.get("content-disposition")).toBe(
      "attachment",
    )
    expect(response.headers.get("content-security-policy")).toBe(
      "sandbox; default-src 'none'",
    )
    expect(response.headers.get("x-content-type-options")).toBe(
      "nosniff",
    )
  })
})
