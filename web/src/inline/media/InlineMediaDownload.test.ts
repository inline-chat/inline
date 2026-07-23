import { afterEach, describe, expect, it, vi } from "vitest"
import {
  downloadInlineMedia,
  inlineDownloadFileName,
} from "./InlineMediaDownload"

afterEach(() => {
  Reflect.deleteProperty(window, "showSaveFilePicker")
  vi.restoreAllMocks()
})

describe("inlineDownloadFileName", () => {
  it("keeps a useful file name without path or control characters", () => {
    expect(inlineDownloadFileName(" ../report:\u0000 final.pdf ")).toBe(
      "..-report-- final.pdf",
    )
  })

  it("streams Chromium downloads to the selected file with byte progress", async () => {
    const written: number[] = []
    const writable = new WritableStream<Uint8Array>({
      write(chunk) {
        written.push(...chunk)
      },
    })
    Object.defineProperty(window, "showSaveFilePicker", {
      configurable: true,
      value: vi.fn(async () => ({
        createWritable: async () => writable,
      })),
    })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(new Uint8Array([1, 2, 3]), {
        headers: { "content-length": "3" },
      }),
    )
    const progress = vi.fn()

    await expect(
      downloadInlineMedia(
        "https://api.inline.chat/file?id=document",
        "report.pdf",
        { onProgress: progress },
      ),
    ).resolves.toEqual({ method: "stream", bytesWritten: 3 })
    expect(written).toEqual([1, 2, 3])
    expect(progress).toHaveBeenLastCalledWith({
      receivedBytes: 3,
      totalBytes: 3,
    })
  })
})
