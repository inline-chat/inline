import { afterEach, describe, expect, it, vi } from "vitest"
import { encodePreview, PREVIEW_QUALITY, previewSize, sendsAsFile, serialProber } from "./attachment-probe"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("attachment probe", () => {
  it("sizes the preview as the server's stripped thumbnail: inside 40 px, never enlarged", () => {
    expect(previewSize(4032, 3024)).toEqual({ width: 40, height: 30 })
    expect(previewSize(1080, 1920)).toEqual({ width: 23, height: 40 })
    expect(previewSize(20, 10)).toEqual({ width: 20, height: 10 })
    expect(previewSize(5000, 10)).toEqual({ width: 40, height: 1 })
  })

  it("applies the Mac's photo-or-file rule (GlassComposeAppKit.shouldSendAsFile)", () => {
    expect(sendsAsFile(49, 49)).toBe(true)
    expect(sendsAsFile(50, 49)).toBe(false)
    expect(sendsAsFile(2100, 100)).toBe(true)
    expect(sendsAsFile(2000, 100)).toBe(false)
    expect(sendsAsFile(100, 2001)).toBe(true)
    expect(sendsAsFile(0, 0)).toBe(false)
  })

  it("runs one probe at a time, in order, and goes on after a failure", async () => {
    const log: string[] = []
    const resolvers: (() => void)[] = []
    const serial = serialProber((file) => {
      const name = (file as File).name
      log.push(`start ${name}`)
      return new Promise((resolve, reject) =>
        resolvers.push(() => {
          log.push(`end ${name}`)
          if (name === "b") reject(new Error("bad"))
          else resolve({})
        }),
      )
    })
    const a = serial(new File([], "a"), "image")
    const b = serial(new File([], "b"), "image")
    const c = serial(new File([], "c"), "video")
    await Promise.resolve()
    expect(log).toEqual(["start a"])
    resolvers.shift()!()
    await a
    await Promise.resolve()
    resolvers.shift()!()
    await expect(b).rejects.toThrow("bad")
    await Promise.resolve()
    resolvers.shift()!()
    await c
    expect(log).toEqual(["start a", "end a", "start b", "end b", "start c", "end c"])
  })

  it("draws on white at the preview size, asks for JPEG at quality 20, and keeps only a JPEG", async () => {
    const calls: unknown[][] = []
    let type = "image/jpeg"
    class FakeCanvas {
      constructor(
        public width: number,
        public height: number,
      ) {
        calls.push(["canvas", width, height])
      }
      getContext() {
        return {
          set fillStyle(value: string) {
            calls.push(["fillStyle", value])
          },
          fillRect: (...args: number[]) => calls.push(["fillRect", ...args]),
          drawImage: (_source: unknown, ...args: number[]) => calls.push(["drawImage", ...args]),
        }
      }
      convertToBlob(options: { type: string; quality: number }) {
        calls.push(["encode", options.type, options.quality])
        return Promise.resolve(new Blob([new Uint8Array([0xff, 0xd8])], { type }))
      }
    }
    vi.stubGlobal("OffscreenCanvas", FakeCanvas)
    const bytes = await encodePreview({} as CanvasImageSource, 800, 400)
    expect(bytes).toEqual(new Uint8Array([0xff, 0xd8]))
    expect(calls).toEqual([
      ["canvas", 40, 20],
      ["fillStyle", "#fff"],
      ["fillRect", 0, 0, 40, 20],
      ["drawImage", 0, 0, 40, 20],
      ["encode", "image/jpeg", PREVIEW_QUALITY],
    ])
    type = "image/png"
    expect(await encodePreview({} as CanvasImageSource, 800, 400)).toBeUndefined()
  })
})
