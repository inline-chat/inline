import type { MediaContent, MessageRow, PhotoInfo } from "@inline/core-protocol"
import type { FileID, PhotoID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { fileIcon, formatDuration, formatFileSize, waveformBars } from "./files"
import { albumLayout, fitMedia, richImageBox, singleMediaBox } from "./layout"
import { groupedMediaLayout, mediaModel } from "./model"
import { strippedJpeg, strippedSize } from "./stripped"
import { bestPhotoSize, photoVariantFor } from "./variants"

const photo = (width: number, height: number, extra: Partial<PhotoInfo> = {}): PhotoInfo => ({
  id: "1" as PhotoID,
  sizes: [
    { type: "b", width: Math.round(width / 10), height: Math.round(height / 10), cdnUrl: "https://cdn/b" },
    { type: "c", width: Math.round(width / 4), height: Math.round(height / 4), fileUniqueId: "c" },
    { type: "f", width, height, cdnUrl: "https://cdn/f" },
  ],
  ...extra,
})

const row = (media: MediaContent, text = ""): Pick<MessageRow, "media" | "text"> => ({ media, text })

describe("stripped thumbnails", () => {
  it("rebuilds a JPEG with the size patched into the SOF0 header, like the Mac", () => {
    const bytes = new Uint8Array([1, 30, 40, 0xaa, 0xbb])
    const jpeg = strippedJpeg(bytes)
    expect(jpeg).toBeDefined()
    if (!jpeg) return
    expect([jpeg[0], jpeg[1]]).toEqual([0xff, 0xd8])
    // SOF0 marker, then length 17, precision 8, then height and width.
    expect([jpeg[140], jpeg[141], jpeg[142], jpeg[143], jpeg[144]]).toEqual([0xff, 0xc0, 0x00, 0x11, 0x08])
    expect([jpeg[145], jpeg[146], jpeg[147], jpeg[148]]).toEqual([0, 30, 0, 40])
    expect(Array.from(jpeg.slice(-4))).toEqual([0xaa, 0xbb, 0xff, 0xd9])
    expect(strippedSize(bytes)).toEqual({ width: 40, height: 30 })
    // Same input object, same output object.
    expect(strippedJpeg(bytes)).toBe(jpeg)
  })

  it("refuses other versions and short input", () => {
    expect(strippedJpeg(new Uint8Array([2, 1, 1, 0]))).toBeUndefined()
    expect(strippedJpeg(new Uint8Array([1, 1]))).toBeUndefined()
    expect(strippedJpeg(undefined)).toBeUndefined()
  })
})

describe("media boxes (Mac calculatePhotoSize)", () => {
  const cases: [string, number, number, Parameters<typeof fitMedia>[2], { width: number; height: number }][] = [
    ["landscape into the 320 box", 1600, 1200, {}, { width: 320, height: 240 }],
    ["portrait into the 320 box", 1200, 1600, {}, { width: 240, height: 320 }],
    ["square", 1000, 1000, {}, { width: 320, height: 320 }],
    ["small is not upscaled", 100, 50, {}, { width: 100, height: 50 }],
    ["small captioned fills the width", 100, 50, { upscale: true }, { width: 320, height: 160 }],
    ["tall panorama", 100, 4000, {}, { width: 8, height: 320 }],
    ["wide panorama", 4000, 100, {}, { width: 320, height: 8 }],
    ["missing dimensions", 0, 0, {}, { width: 40, height: 40 }],
    ["narrow column", 1600, 1200, { availableWidth: 200 }, { width: 200, height: 150 }],
    ["column below the minimum", 1600, 1200, { availableWidth: 10 }, { width: 40, height: 30 }],
    ["sticker box", 512, 512, { maxSide: 120 }, { width: 120, height: 120 }],
    ["minimal style", 1600, 1200, { maxSide: 350, maxHeight: 300 }, { width: 350, height: 263 }],
  ]
  for (const [name, width, height, options, expected] of cases) {
    it(name, () => {
      expect(fitMedia(width, height, options)).toEqual(expected)
    })
  }

  it("uses the photo's best size, the video's own size, then its thumbnail", () => {
    expect(singleMediaBox({ kind: "photo", photo: photo(1600, 1200) })).toEqual({ width: 320, height: 240 })
    expect(singleMediaBox({ kind: "photo", photo: photo(512, 512), sticker: true })).toEqual({ width: 120, height: 120 })
    const video = { id: "2" as FileID, width: 0, height: 0, duration: 3, size: 1, thumbnail: photo(1280, 720) }
    expect(singleMediaBox({ kind: "video", video })).toEqual({ width: 320, height: 180 })
    expect(singleMediaBox({ kind: "nudge" })).toBeUndefined()
  })

  it("sizes rich images and albums by the Mac planner", () => {
    expect(richImageBox({ width: 2000, height: 1000 })).toEqual({ width: 420, height: 210 })
    expect(richImageBox({ width: 2000, height: 1000 }, 300)).toEqual({ width: 300, height: 150 })
    expect(richImageBox(undefined)).toEqual({ width: 240, height: 180 })
    expect(richImageBox({ width: 100, height: 80 })).toEqual({ width: 100, height: 80 })
    const album = albumLayout([{ width: 1000, height: 1000 }, { width: 100, height: 1000 }, { width: 4000, height: 100 }, undefined])
    expect(album?.items.map((item) => item.width)).toEqual([126, 96, 220, 168])
    expect(album?.items.map((item) => item.x)).toEqual([0, 132, 234, 460])
    expect(album?.height).toBe(126)
    expect(albumLayout([])).toBeUndefined()
    expect(albumLayout(Array.from({ length: 11 }, () => undefined))).toBeUndefined()
  })
})

describe("variants", () => {
  it("picks the Mac's best size: source, then class, then area", () => {
    expect(bestPhotoSize(photo(1600, 1200))?.type).toBe("f")
    expect(bestPhotoSize({ id: "1" as PhotoID, sizes: [{ type: "f", width: 9, height: 9 }, { type: "b", width: 1, height: 1, cdnUrl: "x" }] })?.type).toBe("b")
    expect(bestPhotoSize(undefined)).toBeUndefined()
  })

  it("asks for the smallest size that covers the box at the pixel ratio", () => {
    const info = photo(1600, 1200)
    expect(photoVariantFor(info, { width: 100, height: 75 })?.size.type).toBe("b")
    expect(photoVariantFor(info, { width: 320, height: 240 })?.size.type).toBe("c")
    expect(photoVariantFor(info, { width: 320, height: 240 }, 2)?.size.type).toBe("f")
    expect(photoVariantFor(info, { width: 4000, height: 3000 })).toEqual({ size: info.sizes[2], undersized: true })
  })
})

describe("files and voice", () => {
  it("formats sizes like ByteCountFormatter .file", () => {
    expect(formatFileSize(0, "en")).toBe("0 bytes")
    expect(formatFileSize(1, "en")).toBe("1 byte")
    expect(formatFileSize(999, "en")).toBe("999 bytes")
    expect(formatFileSize(52_000, "en")).toBe("52 KB")
    expect(formatFileSize(999_600, "en")).toBe("1 MB")
    expect(formatFileSize(9_500_000, "en")).toBe("9.5 MB")
    expect(formatFileSize(1_250_000_000, "en")).toBe("1.25 GB")
    expect(formatFileSize(1_500_000, "de")).toBe("1,5 MB")
    expect(formatFileSize(Number.NaN, "en")).toBe("0 bytes")
  })

  it("formats durations", () => {
    expect(formatDuration(7)).toBe("0:07")
    expect(formatDuration(75)).toBe("1:15")
    expect(formatDuration(3723)).toBe("1:02:03")
    expect(formatDuration(-3)).toBe("0:00")
  })

  it("picks file icons by MIME type, then extension", () => {
    expect(fileIcon("application/pdf", "x.bin")).toBe("pdf")
    expect(fileIcon("application/octet-stream", "notes.md")).toBe("text")
    expect(fileIcon("application/zip", "a")).toBe("archive")
    expect(fileIcon("", "deck.KEY")).toBe("presentation")
    expect(fileIcon("", "README")).toBe("document")
  })

  it("draws 48 waveform bars between 0.12 and 1", () => {
    const flat = waveformBars(undefined)
    expect(flat).toHaveLength(48)
    expect(new Set(flat)).toEqual(new Set([0.12]))
    const bars = waveformBars(new Uint8Array([0, 255, 0, 128, 64, 255, 10, 0]))
    expect(bars).toHaveLength(48)
    expect(Math.max(...bars)).toBe(1)
    expect(Math.min(...bars)).toBeGreaterThanOrEqual(0.12)
  })
})

describe("media model", () => {
  const stripped = new Uint8Array([1, 3, 4, 9])

  it("builds photo, sticker, video, GIF, document, voice and nudge models", () => {
    const photoModel = mediaModel(row({ kind: "photo", photo: photo(1600, 1200, { stripped, format: "png" }) }))
    expect(photoModel).toMatchObject({ kind: "photo", box: { width: 320, height: 240 }, noBubble: true, sticker: false })
    expect(photoModel?.kind === "photo" && photoModel.preview?.[0]).toBe(0xff)
    const captioned = mediaModel(row({ kind: "photo", photo: photo(100, 50, { format: "png" }) }, "caption"))
    expect(captioned).toMatchObject({ box: { width: 320, height: 160 }, noBubble: false })
    const sticker = mediaModel(row({ kind: "photo", photo: photo(512, 512, { stripped }), sticker: true }))
    expect(sticker).toMatchObject({ kind: "photo", sticker: true, noBubble: true, preview: undefined, box: { width: 120, height: 120 } })

    const video = { id: "2" as FileID, width: 1280, height: 720, duration: 75, size: 1 }
    expect(mediaModel(row({ kind: "video", video }))).toMatchObject({ kind: "video", durationText: "1:15", box: { width: 320, height: 180 } })
    expect(mediaModel(row({ kind: "video", video: { ...video, animated: true } }))).toMatchObject({ kind: "gif", durationText: undefined })

    expect(
      mediaModel(
        row({ kind: "document", document: { id: "3" as FileID, fileName: "plan.pdf", mimeType: "application/pdf", size: 52_000 } }),
        { locale: "en" },
      ),
    ).toMatchObject({ kind: "document", name: "plan.pdf", extension: "pdf", icon: "pdf", sizeText: "52 KB", height: 36 })
    expect(
      mediaModel(row({ kind: "voice", voice: { id: "4" as FileID, duration: 12, size: 30_000, mimeType: "audio/ogg" } }), { locale: "en" }),
    ).toMatchObject({ kind: "voice", durationText: "0:12", width: 216, height: 44 })
    expect(mediaModel(row({ kind: "nudge" }, "👋"))).toEqual({ kind: "nudge", key: "nudge" })
    expect(mediaModel({ text: "" })).toBeUndefined()
  })

  it("lays out grouped media messages as an album strip", () => {
    const rows = [row({ kind: "photo", photo: photo(1000, 1000) }), row({ kind: "photo", photo: photo(2000, 1000) })]
    expect(groupedMediaLayout(rows)?.items.map((item) => item.width)).toEqual([126, 220])
    expect(groupedMediaLayout(rows.slice(0, 1))).toBeUndefined()
    expect(groupedMediaLayout([...rows, row({ kind: "nudge" })])).toBeUndefined()
  })
})
