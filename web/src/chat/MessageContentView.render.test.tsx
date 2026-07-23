import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MessageContentView } from "./MessageContentView"
import { InlineMediaProvider } from "../inline/media/InlineMediaContext"
import { InlineMediaRepository } from "../inline/media/InlineMediaRepository"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

afterEach(cleanup)

describe("MessageContentView first frame", () => {
  it("lays out final media geometry with the tiny thumbnail already rendered", () => {
    const tinyThumbnailUrl =
      "data:image/jpeg;base64,/9j/2Q=="
    const { container } = render(
      <MessageContentView
        presentation={{
          media: {
            kind: "photo",
            mediaKey: "photo:1:d",
            remoteUrl: "https://cdn.inline.chat/photo-1",
            tinyThumbnailUrl,
            width: 800,
            height: 600,
            label: "Photo",
          },
        }}
      />,
    )

    const fullImage = screen.getByAltText("Photo")
    const frame = fullImage.parentElement
    const tinyImage = container.querySelector(
      `img[src="${tinyThumbnailUrl}"]`,
    )

    expect(tinyImage).toBeInTheDocument()
    expect(tinyImage).toHaveAttribute("aria-hidden", "true")
    expect(frame).toHaveStyle({ width: "320px", height: "240px" })
  })

  it("keeps an uncached owner-managed photo on its tiny thumbnail until cached bytes arrive", async () => {
    let resolveLoad: ((resource: {
      kind: "blob"
      blob: Blob
    }) => void) | undefined
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(
        () =>
          new Promise<{ kind: "blob"; blob: Blob }>((resolve) => {
            resolveLoad = resolve
          }),
      ),
    }
    const repository = new InlineMediaRepository(source)
    const createObjectUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:inline-photo-1")
    const remoteUrl = "https://api.inline.chat/file?id=photo-1"

    const { container } = render(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "photo",
              mediaKey: "photo:1:d",
              remoteUrl,
              tinyThumbnailUrl: "data:image/jpeg;base64,/9j/2Q==",
              width: 800,
              height: 600,
              label: "Photo",
            },
          }}
        />
      </InlineMediaProvider>,
    )

    expect(container.querySelector(`img[src="${remoteUrl}"]`)).toBeNull()
    expect(screen.queryByAltText("Photo")).toBeNull()
    expect(source.load).toHaveBeenCalledOnce()

    resolveLoad?.({
      kind: "blob",
      blob: new Blob(["inline-photo"]),
    })

    await waitFor(() => {
      expect(screen.getByAltText("Photo")).toHaveAttribute(
        "src",
        "blob:inline-photo-1",
      )
    })
    expect(createObjectUrl).toHaveBeenCalledOnce()
  })

  it("never reuses the previous photo URL for a new media identity", async () => {
    const source = {
      loadCached: vi.fn(async (key: string) =>
        key === "photo:1:d"
          ? {
              kind: "blob" as const,
              blob: new Blob(["first"]),
            }
          : undefined,
      ),
      load: vi.fn(
        () => new Promise<{ kind: "blob"; blob: Blob }>(() => undefined),
      ),
    }
    const repository = new InlineMediaRepository(source)
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:inline-photo-1")
    await repository.promoteCached("photo:1:d")

    const { rerender } = render(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "photo",
              mediaKey: "photo:1:d",
              remoteUrl: "https://api.inline.chat/file?id=photo-1",
              width: 800,
              height: 600,
              label: "Photo",
            },
          }}
        />
      </InlineMediaProvider>,
    )
    expect(screen.getByAltText("Photo")).toHaveAttribute(
      "src",
      "blob:inline-photo-1",
    )

    rerender(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "photo",
              mediaKey: "photo:2:d",
              remoteUrl: "https://api.inline.chat/file?id=photo-2",
              tinyThumbnailUrl: "data:image/jpeg;base64,/9j/2Q==",
              width: 800,
              height: 600,
              label: "Photo",
            },
          }}
        />
      </InlineMediaProvider>,
    )

    expect(screen.queryByAltText("Photo")).toBeNull()
    expect(document.querySelector('img[src="blob:inline-photo-1"]')).toBeNull()
  })

  it("hands video URLs to native Range playback without whole-blob acquisition", () => {
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(),
    }
    const repository = new InlineMediaRepository(source)
    const streamUrl =
      "https://api.inline.chat/file?id=INVstable&exp=2&sig=signed"

    render(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "video",
              mediaKey: "video:10",
              remoteUrl: streamUrl,
              width: 640,
              height: 360,
              animated: false,
              label: "Video",
            },
          }}
        />
      </InlineMediaProvider>,
    )

    expect(screen.getByLabelText("Video")).toHaveAttribute(
      "src",
      streamUrl,
    )
    expect(screen.getByLabelText("Video")).not.toHaveAttribute(
      "controls",
    )
    expect(source.load).not.toHaveBeenCalled()
    expect(source.loadCached).not.toHaveBeenCalled()
  })
})
