import { describe, expect, test } from "bun:test"
import type { IncomingMessage } from "node:http"
import sharp from "sharp"
import {
  downloadBlockImage,
  remoteBlockImageAcceptHeader,
  RemoteBlockImageError,
  resolvePublicImageUrl,
  type RemoteImageRequest,
} from "./blockContentRemoteImage"

const publicAddress = { address: "93.184.216.34", family: 4 } as const

function response(input: {
  status?: number
  headers?: Record<string, string>
  bytes?: Uint8Array
}): IncomingMessage {
  const bytes = input.bytes
  return {
    statusCode: input.status ?? 200,
    headers: input.headers ?? {},
    resume() {},
    destroy() {},
    async *[Symbol.asyncIterator]() {
      if (bytes) yield Buffer.from(bytes)
    },
  } as unknown as IncomingMessage
}

async function pngBytes(): Promise<Buffer> {
  return sharp({
    create: {
      width: 2,
      height: 2,
      channels: 4,
      background: { r: 20, g: 40, b: 60, alpha: 1 },
    },
  }).png().toBuffer()
}

async function jpegBytes(): Promise<Buffer> {
  return sharp({
    create: {
      width: 2,
      height: 2,
      channels: 3,
      background: { r: 20, g: 40, b: 60 },
    },
  }).jpeg().toBuffer()
}

describe("remote block image boundary", () => {
  test("advertises only formats accepted by decoded validation", () => {
    expect(remoteBlockImageAcceptHeader).toBe("image/webp,image/png,image/jpeg,image/gif")
    expect(remoteBlockImageAcceptHeader).not.toContain("avif")
    expect(remoteBlockImageAcceptHeader).not.toContain("image/*")
  })

  test("accepts a public address and strips fragments", async () => {
    const result = await resolvePublicImageUrl("https://example.com/image.png#secret", async () => [
      publicAddress,
    ])
    expect(result.url.toString()).toBe("https://example.com/image.png")
    expect(result.address).toBe("93.184.216.34")
  })

  test("rejects credentials, scheme-mismatched ports, and private resolution", async () => {
    const cases = [
      resolvePublicImageUrl("https://user:pass@example.com/image.png"),
      resolvePublicImageUrl("https://example.com:444/image.png"),
      resolvePublicImageUrl("http://example.com:443/image.png"),
      resolvePublicImageUrl("https://example.com/image.png", async () => [{ address: "127.0.0.1", family: 4 }]),
      resolvePublicImageUrl("http://[::1]/image.png"),
    ]
    for (const result of cases) {
      await expect(result).rejects.toBeInstanceOf(RemoteBlockImageError)
    }
  })

  test("filters mixed DNS answers and pins only public candidates", async () => {
    const result = await resolvePublicImageUrl("https://example.com/image.png", async () => [
      { address: "10.0.0.1", family: 4 },
      publicAddress,
      { address: "2001:db8::1", family: 6 },
    ])

    expect(result.address).toBe(publicAddress.address)
    expect(result.candidates).toEqual([publicAddress])
    expect(result.diagnostic).toMatchObject({
      cause: "non_public_candidates_filtered",
      hostname: "example.com",
      answerCount: 3,
      publicAnswerCount: 1,
      filteredAnswerCount: 2,
    })
  })

  test("blocks an all-non-public answer set with privacy-safe diagnostics", async () => {
    const source = "https://private.example/secret/path.png?token=do-not-log"
    const result = resolvePublicImageUrl(source, async () => [
      { address: "127.0.0.1", family: 4 },
      { address: "fd00::1", family: 6 },
    ])

    await expect(result).rejects.toMatchObject({
      code: "blocked_address",
      permanent: true,
      diagnostic: {
        cause: "dns_no_public_candidate",
        hostname: "private.example",
        answerCount: 2,
        publicAnswerCount: 0,
      },
    })
    const error = await result.catch((caught) => caught as RemoteBlockImageError)
    expect(JSON.stringify(error.diagnostic)).not.toContain("secret")
    expect(JSON.stringify(error.diagnostic)).not.toContain("do-not-log")
    expect(JSON.stringify(error.diagnostic)).not.toContain("127.0.0.1")
  })

  test("uses precise special-address classification", async () => {
    await expect(resolvePublicImageUrl("https://example.com/image.png", async () => [
      { address: "192.0.2.1", family: 4 },
    ])).rejects.toMatchObject({ code: "blocked_address" })

    const public192 = await resolvePublicImageUrl("https://example.com/image.png", async () => [
      { address: "192.0.10.1", family: 4 },
    ])
    expect(public192.address).toBe("192.0.10.1")

    const mapped = await resolvePublicImageUrl("http://[::ffff:93.184.216.34]/image.png")
    expect(mapped.family).toBe(6)
    expect(mapped.diagnostic.hostname).toBe("ip_literal_v6")
  })

  test("revalidates every redirect target", async () => {
    const request: RemoteImageRequest = async () => response({
      status: 302,
      headers: { location: "https://private.example/final.png" },
    })
    const lookup = async (hostname: string) => hostname === "private.example"
      ? [{ address: "10.0.0.1", family: 4 }]
      : [publicAddress]

    await expect(downloadBlockImage("https://public.example/start.png", { lookup, request }))
      .rejects.toMatchObject({
        code: "blocked_address",
        diagnostic: { cause: "dns_no_public_candidate", hostname: "private.example", redirectHop: 1 },
      })
  })

  test("rejects HTTPS to HTTP redirect downgrade", async () => {
    const request: RemoteImageRequest = async () => response({
      status: 302,
      headers: { location: "http://cdn.example/final.png" },
    })
    await expect(downloadBlockImage("https://public.example/start.png", {
      lookup: async () => [publicAddress],
      request,
    })).rejects.toMatchObject({
      code: "invalid_redirect",
      diagnostic: { cause: "redirect_downgrade", hostname: "public.example" },
    })
  })

  test("fails over only between validated public candidates", async () => {
    const attempted: string[] = []
    const png = await pngBytes()
    const request: RemoteImageRequest = async (target) => {
      attempted.push(target.address)
      if (attempted.length === 1) throw new Error("unreachable")
      return response({ headers: { "content-type": "image/png" }, bytes: png })
    }

    const image = await downloadBlockImage("https://images.example/image.png", {
      lookup: async () => [
        { address: "2606:2800:220:1:248:1893:25c8:1946", family: 6 },
        { address: "2606:2800:220:1:248:1893:25c8:1947", family: 6 },
        { address: "93.184.216.34", family: 4 },
        { address: "10.0.0.1", family: 4 },
      ],
      request,
    })
    expect(image.contentType).toBe("image/png")
    expect(attempted).toEqual(["2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34"])
  })

  test("applies one total deadline to DNS, redirects, and body work", async () => {
    const request: RemoteImageRequest = async (_target, signal) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true })
    })

    await expect(downloadBlockImage("https://slow.example/image.png", {
      lookup: async () => [publicAddress],
      request,
      totalTimeoutMs: 5,
    })).rejects.toMatchObject({ code: "total_timeout", permanent: false })
  })

  test("rejects bodies whose declared type does not match decoded image", async () => {
    const png = await pngBytes()
    const request: RemoteImageRequest = async () => response({
      headers: { "content-type": "image/jpeg" },
      bytes: png,
    })
    await expect(downloadBlockImage("https://images.example/image.jpg", {
      lookup: async () => [publicAddress],
      request,
    })).rejects.toMatchObject({
      code: "invalid_image",
      diagnostic: { cause: "content_type_mismatch", hostname: "images.example" },
    })
  })

  test("uses safely decoded type when metadata is absent or generic", async () => {
    const png = await pngBytes()
    for (const contentType of [undefined, "application/octet-stream"]) {
      const request: RemoteImageRequest = async () => response({
        headers: contentType ? { "content-type": contentType } : {},
        bytes: png,
      })
      const image = await downloadBlockImage("https://images.example/image", {
        lookup: async () => [publicAddress],
        request,
      })
      expect(image.contentType).toBe("image/png")
    }
  })

  test("normalizes the common image/jpg alias after decode", async () => {
    const jpeg = await jpegBytes()
    const image = await downloadBlockImage("https://images.example/image.jpg", {
      lookup: async () => [publicAddress],
      request: async () => response({ headers: { "content-type": "image/jpg" }, bytes: jpeg }),
    })
    expect(image.contentType).toBe("image/jpeg")
  })
})
