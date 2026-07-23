import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InlineFileDownloadView } from "./InlineFileDownloadView"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

afterEach(() => {
  Reflect.deleteProperty(window, "showSaveFilePicker")
  vi.restoreAllMocks()
})

describe("InlineFileDownloadView", () => {
  it("turns a failed document download into an explicit retry action", async () => {
    Object.defineProperty(window, "showSaveFilePicker", {
      configurable: true,
      value: vi.fn(async () => ({
        createWritable: async () => new WritableStream<Uint8Array>(),
      })),
    })
    const fetcher = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response(null, { status: 503 }))

    render(
      <InlineFileDownloadView
        media={{
          kind: "document",
          mediaKey: "document:alpha-notes",
          fileName: "alpha-notes.pdf",
          size: 42_000,
          remoteUrl: "https://api.inline.chat/file?id=alpha-notes",
          label: "alpha-notes.pdf",
        }}
      />,
    )

    const download = screen.getByRole("button", {
      name: /alpha-notes\.pdf/i,
    })
    fireEvent.click(download)

    const failure = await screen.findByRole("alert")
    expect(failure).toHaveTextContent("Download failed · Retry")
    expect(failure).toHaveAttribute(
      "title",
      "Inline media download failed (503)",
    )

    fireEvent.click(download)
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2))
  })

  it("cancels an in-flight stream and returns the file control to idle", async () => {
    const aborted = vi.fn()
    const writable = new WritableStream<Uint8Array>({ abort: aborted })
    Object.defineProperty(window, "showSaveFilePicker", {
      configurable: true,
      value: vi.fn(async () => ({
        createWritable: async () => writable,
      })),
    })
    let requestSignal: AbortSignal | undefined
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      requestSignal = init?.signal ?? undefined
      return new Response(new ReadableStream<Uint8Array>({ start() {} }))
    })

    render(
      <InlineFileDownloadView
        media={{
          kind: "document",
          mediaKey: "document:cancel",
          fileName: "cancel-me.pdf",
          size: 42_000,
          remoteUrl: "https://api.inline.chat/file?id=cancel-me",
          label: "cancel-me.pdf",
        }}
      />,
    )

    const download = screen.getByRole("button", {
      name: /cancel-me\.pdf/i,
    })
    fireEvent.click(download)
    await waitFor(() => expect(download).toHaveAttribute("aria-busy", "true"))
    fireEvent.click(download)

    await waitFor(() => expect(download).not.toHaveAttribute("aria-busy"))
    expect(download).toHaveTextContent("42 KB")
    expect(requestSignal?.aborted).toBe(true)
    await waitFor(() => expect(aborted).toHaveBeenCalledOnce())
  })
})
