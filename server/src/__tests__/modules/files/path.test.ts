import { describe, expect, it } from "bun:test"
import {
  getSignedMediaFileProxyUrl,
  getSignedMediaPhotoUrl,
  MEDIA_FILE_ROUTE_PATH,
  PHOTO_MEDIA_ROUTE_PATH,
  verifySignedMediaFileUrl,
  verifySignedMediaPhotoUrl,
} from "@in/server/modules/files/path"

describe("media file url signing", () => {
  const signingKey = "test-photo-signing-key"
  const baseUrl = "https://api.inline.chat"
  const now = 1_700_000_000
  const fileUniqueId = "INPabcdefghijklmnopqrstu"

  it("creates a signed photo url under /file and verifies it", () => {
    const url = getSignedMediaPhotoUrl(fileUniqueId, 120, { baseUrl, signingKey, now, useProxy: true })

    expect(url).toBeDefined()
    const parsed = new URL(url!)
    expect(parsed.pathname).toBe(PHOTO_MEDIA_ROUTE_PATH)

    const signedFileId = parsed.searchParams.get("id")
    const expRaw = parsed.searchParams.get("exp")
    const sig = parsed.searchParams.get("sig")

    expect(signedFileId).toBe(fileUniqueId)
    expect(expRaw).toBe(String(now + 120))
    expect(sig).toBeString()
    expect(
      verifySignedMediaPhotoUrl({
        fileUniqueId: signedFileId!,
        exp: Number(expRaw),
        sig: sig!,
        now,
        signingKey,
      }),
    ).toBe(true)
  })

  it("creates a generalized file capability only through the explicit proxy API", () => {
    const url = getSignedMediaFileProxyUrl(
      {
        fileUniqueId: "INVabcdefghijklmnopqrstu",
        path: "private/video.mp4",
      },
      120,
      { baseUrl, signingKey, now },
    )

    expect(url).toBeDefined()
    const parsed = new URL(url!)
    expect(parsed.pathname).toBe(MEDIA_FILE_ROUTE_PATH)
    expect(parsed.searchParams.get("id")).toBe(
      "INVabcdefghijklmnopqrstu",
    )
    expect(
      verifySignedMediaFileUrl({
        fileUniqueId: parsed.searchParams.get("id")!,
        exp: Number(parsed.searchParams.get("exp")),
        sig: parsed.searchParams.get("sig")!,
        now,
        signingKey,
      }),
    ).toBe(true)
  })

  it("rejects tampered file id", () => {
    const url = getSignedMediaPhotoUrl(fileUniqueId, 120, { baseUrl, signingKey, now, useProxy: true })
    const parsed = new URL(url!)
    const exp = Number(parsed.searchParams.get("exp"))
    const sig = parsed.searchParams.get("sig")!

    expect(
      verifySignedMediaPhotoUrl({
        fileUniqueId: "INPotherIdMASDFGHJKLQW12",
        exp,
        sig,
        now,
        signingKey,
      }),
    ).toBe(false)
  })

  it("rejects expired urls", () => {
    const url = getSignedMediaPhotoUrl(fileUniqueId, 10, { baseUrl, signingKey, now, useProxy: true })
    const parsed = new URL(url!)

    expect(
      verifySignedMediaPhotoUrl({
        fileUniqueId,
        exp: Number(parsed.searchParams.get("exp")),
        sig: parsed.searchParams.get("sig")!,
        now: now + 11,
        signingKey,
      }),
    ).toBe(false)
  })

  it("rejects invalid file unique id format", () => {
    const exp = now + 300
    const sigUrl = getSignedMediaPhotoUrl(fileUniqueId, 300, { baseUrl, signingKey, now, useProxy: true })!
    const sig = new URL(sigUrl).searchParams.get("sig")!

    expect(
      verifySignedMediaPhotoUrl({
        fileUniqueId: "../unsafe-file",
        exp,
        sig,
        now,
        signingKey,
      }),
    ).toBe(false)
  })
})
