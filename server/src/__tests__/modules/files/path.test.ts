import { describe, expect, it } from "bun:test"
import { getSignedMediaPhotoUrl, PHOTO_MEDIA_ROUTE_PATH, verifySignedMediaPhotoUrl } from "@in/server/modules/files/path"

describe("media photo url signing", () => {
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
