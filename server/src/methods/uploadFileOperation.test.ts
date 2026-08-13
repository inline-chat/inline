import { describe, expect, test } from "bun:test"
import {
  uploadDocumentWithOptionalThumbnail,
  uploadOptionalDocumentThumbnail,
  usableOptionalDocumentThumbnail,
} from "./uploadFileOperation"

describe("optional document thumbnail upload", () => {
  test("returns the uploaded photo id", async () => {
    const thumbnail = new File(["thumbnail"], "thumbnail.jpg", { type: "image/jpeg" })
    const photoId = await uploadOptionalDocumentThumbnail(
      thumbnail,
      42,
      async () => ({ fileUniqueId: "thumb", photoId: 101 }),
    )

    expect(photoId).toBe(101)
  })

  test("does not fail the document when the optional thumbnail fails", async () => {
    const document = new File(["document"], "report.pdf", { type: "application/pdf" })
    const thumbnail = new File(["thumbnail"], "thumbnail.jpg", { type: "image/jpeg" })
    let uploadedWithoutThumbnail = false
    const result = await uploadDocumentWithOptionalThumbnail(
      document,
      thumbnail,
      42,
      async () => {
        throw new Error("thumbnail storage unavailable")
      },
      async (_file, thumbnailId) => {
        uploadedWithoutThumbnail = thumbnailId === undefined
        return { fileUniqueId: "document", documentId: 202 }
      },
    )

    expect(uploadedWithoutThumbnail).toBe(true)
    expect(result.documentId).toBe(202)
  })

  test("ignores an invalid optional document thumbnail", () => {
    const emptyThumbnail = new File([], "thumbnail.jpg", { type: "image/jpeg" })

    expect(usableOptionalDocumentThumbnail(emptyThumbnail, 42)).toBeUndefined()
  })

  test("uploads the document when optional thumbnail validation removes the thumbnail", async () => {
    const document = new File(["document"], "report.pdf", { type: "application/pdf" })
    const invalidThumbnail = new File([], "thumbnail.jpg", { type: "image/jpeg" })
    const thumbnail = usableOptionalDocumentThumbnail(invalidThumbnail, 42)
    let uploadedWithoutThumbnail = false

    const result = await uploadDocumentWithOptionalThumbnail(
      document,
      thumbnail,
      42,
      async () => {
        throw new Error("thumbnail uploader must not run")
      },
      async (_file, thumbnailId) => {
        uploadedWithoutThumbnail = thumbnailId === undefined
        return { fileUniqueId: "document", documentId: 203 }
      },
    )

    expect(uploadedWithoutThumbnail).toBe(true)
    expect(result.documentId).toBe(203)
  })
})
