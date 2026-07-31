import { describe, expect, test } from "bun:test"
import { ExternalProfilePhotoStatus, ExternalProfileProvider } from "@inline-chat/protocol/core"
import type { FetchImpl, LookupFn } from "@inline-chat/url-preview"
import { ExternalProfilePhotoResolver, normalizeExternalUsername } from "./externalProfilePhoto"

const publicLookup: LookupFn = async () => [{ address: "93.184.216.34", family: 4 }]

describe("external profile photo resolver", () => {
  test("normalizes typed X handles and profile URLs", () => {
    expect(normalizeExternalUsername(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, " @morajabi ")).toBe(
      "morajabi",
    )
    expect(
      normalizeExternalUsername(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "https://x.com/morajabi"),
    ).toBe("morajabi")
    expect(normalizeExternalUsername(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "not valid!")).toBeNull()
  })

  test("selects the X profile og:image instead of the banner and upgrades its size", async () => {
    const requests: string[] = []
    const photo = new Uint8Array([1, 2, 3, 4])
    const fetchImpl: FetchImpl = async (input) => {
      const url = input.toString()
      requests.push(url)
      if (url === "https://x.com/morajabi") {
        return new Response(
          `<html><head>
            <meta name="twitter:image" content="https://pbs.twimg.com/profile_banners/1/banner">
            <meta property="og:image" content="https://pbs.twimg.com/profile_images/123/avatar_200x200.jpg">
          </head></html>`,
          { headers: { "content-type": "text/html; charset=utf-8" } },
        )
      }
      if (url === "https://pbs.twimg.com/profile_images/123/avatar_400x400.jpg") {
        return new Response(photo, { headers: { "content-type": "image/jpeg" } })
      }
      return new Response(null, { status: 404 })
    }

    const resolver = new ExternalProfilePhotoResolver({ fetchImpl, lookup: publicLookup })
    const result = await resolver.resolve(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "morajabi")

    expect(result.status).toBe(ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_FOUND)
    expect(result.mimeType).toBe("image/jpeg")
    expect(result.photo).toEqual(photo)
    expect(requests).toEqual([
      "https://x.com/morajabi",
      "https://pbs.twimg.com/profile_images/123/avatar_400x400.jpg",
    ])
  })

  test("rejects non-profile image hosts and paths", async () => {
    const fetchImpl: FetchImpl = async () =>
      new Response(
        `<meta property="og:image" content="https://attacker.example/profile_images/123/avatar.jpg">`,
        { headers: { "content-type": "text/html" } },
      )
    const resolver = new ExternalProfilePhotoResolver({ fetchImpl, lookup: publicLookup })

    const result = await resolver.resolve(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "morajabi")

    expect(result.status).toBe(ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_NOT_FOUND)
    expect(result.photo).toHaveLength(0)
  })

  test("rejects oversized avatar responses before reading the body", async () => {
    const fetchImpl: FetchImpl = async (input) =>
      input.toString().startsWith("https://x.com/")
        ? new Response(
            `<meta property="og:image" content="https://pbs.twimg.com/profile_images/123/avatar_200x200.jpg">`,
            { headers: { "content-type": "text/html" } },
          )
        : new Response(new Uint8Array([1]), {
            headers: {
              "content-length": String(2 * 1024 * 1024),
              "content-type": "image/jpeg",
            },
          })
    const resolver = new ExternalProfilePhotoResolver({ fetchImpl, lookup: publicLookup })

    const result = await resolver.resolve(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "morajabi")

    expect(result.status).toBe(ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_UNAVAILABLE)
    expect(result.photo).toHaveLength(0)
  })

  test("caches a successful bounded lookup", async () => {
    let fetchCount = 0
    const fetchImpl: FetchImpl = async (input) => {
      fetchCount += 1
      return input.toString().startsWith("https://x.com/")
        ? new Response(
            `<meta property="og:image" content="https://pbs.twimg.com/profile_images/123/avatar_normal.jpg">`,
            { headers: { "content-type": "text/html" } },
          )
        : new Response(new Uint8Array([1]), { headers: { "content-type": "image/jpeg" } })
    }
    const resolver = new ExternalProfilePhotoResolver({ fetchImpl, lookup: publicLookup })

    await resolver.resolve(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "morajabi")
    await resolver.resolve(ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X, "MORAJABI")

    expect(fetchCount).toBe(2)
  })
})
