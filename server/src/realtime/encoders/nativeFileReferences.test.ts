import { describe, expect, test } from "bun:test"
import { Document, Photo, Video, Voice } from "@inline-chat/protocol/core"
import type { DbFullDocument, DbFullPhoto, DbFullPhotoSize, DbFullPlainFile, DbFullVideo, DbFullVoice } from "@in/server/db/models/files"
import { encodeDocument } from "./encodeDocument"
import { encodePhoto } from "./encodePhoto"
import { encodeVideo } from "./encodeVideo"
import { encodeVoice } from "./encodeVoice"

const date = new Date("2026-08-30T00:00:00Z")
const file = (fileUniqueId: string): DbFullPlainFile => ({
  id: 1, fileUniqueId, fileSize: 3, mimeType: "audio/ogg", path: null, date,
} as DbFullPlainFile)

describe("native file references in media payloads", () => {
  test("received document, video and voice carry a round-trippable original file ID", () => {
    const document = encodeDocument({ document: { id: 1, date, file: file("IND_original"), fileName: "file.bin" } as DbFullDocument })
    const video = encodeVideo({ video: { id: 2, date, file: file("INV_original") } as DbFullVideo })
    const voice = encodeVoice({ voice: { id: 3, date, file: file("INW_original"), waveform: Buffer.from([1]) } as DbFullVoice })
    expect(Document.fromBinary(Document.toBinary(document)).fileUniqueId).toBe("IND_original")
    expect(Video.fromBinary(Video.toBinary(video)).fileUniqueId).toBe("INV_original")
    expect(Voice.fromBinary(Voice.toBinary(voice!)).fileUniqueId).toBe("INW_original")
    expect(document.id).toBe(1n)
    expect(video.id).toBe(2n)
    expect(voice!.id).toBe(3n)
  })

  test("each stored photo size identifies its own bytes", () => {
    const photo = encodePhoto({ photo: {
      id: 4, date, format: "jpeg", photoSizes: [
        { size: "b", width: 140, height: 140, file: file("INP_small") } as DbFullPhotoSize,
        { size: "f", width: 1000, height: 1000, file: file("INP_large") } as DbFullPhotoSize,
      ],
    } as DbFullPhoto })
    const decoded = Photo.fromBinary(Photo.toBinary(photo))
    expect(decoded.fileUniqueId).toBe("INP_large")
    expect(decoded.sizes.map((size) => size.fileUniqueId)).toEqual(["INP_small", "INP_large"])
  })
})
