import { afterEach, describe, expect, test, setSystemTime } from "bun:test"
import {
  createVideoMultipartSessionToken,
  verifyVideoMultipartSessionToken,
} from "@in/server/modules/files/multipartUploadSession"

afterEach(() => {
  setSystemTime()
})

describe("multipartUploadSession", () => {
  test("creates and verifies a valid session token", () => {
    const base = 1
    setSystemTime(new Date(base))

    const token = createVideoMultipartSessionToken({
      userId: 42,
      uploadId: "upload-1",
      fileUniqueId: "INV123",
      path: "INV123/prefix.mp4",
      bucketPath: "files/INV123/prefix.mp4",
      fileName: "video.mp4",
      mimeType: "video/mp4",
      extension: "mp4",
      fileSize: 2_000_000,
      width: 1280,
      height: 720,
      duration: 9,
      partSize: 8 * 1024 * 1024,
      totalParts: 1,
    })

    const verified = verifyVideoMultipartSessionToken(token)
    expect(verified).not.toBeNull()
    expect(verified?.userId).toBe(42)
    expect(verified?.uploadId).toBe("upload-1")
    expect(verified?.fileUniqueId).toBe("INV123")
    expect(verified?.mimeType).toBe("video/mp4")
  })

  test("rejects a tampered session token", () => {
    const token = createVideoMultipartSessionToken({
      userId: 42,
      uploadId: "upload-1",
      fileUniqueId: "INV123",
      path: "INV123/prefix.mp4",
      bucketPath: "files/INV123/prefix.mp4",
      fileName: "video.mp4",
      mimeType: "video/mp4",
      extension: "mp4",
      fileSize: 2_000_000,
      width: 1280,
      height: 720,
      duration: 9,
      partSize: 8 * 1024 * 1024,
      totalParts: 1,
    })

    const tampered = `${token}tampered`
    expect(verifyVideoMultipartSessionToken(tampered)).toBeNull()
  })

  test("rejects expired session token", () => {
    const base = 1
    setSystemTime(new Date(base))

    const token = createVideoMultipartSessionToken({
      userId: 42,
      uploadId: "upload-1",
      fileUniqueId: "INV123",
      path: "INV123/prefix.mp4",
      bucketPath: "files/INV123/prefix.mp4",
      fileName: "video.mp4",
      mimeType: "video/mp4",
      extension: "mp4",
      fileSize: 2_000_000,
      width: 1280,
      height: 720,
      duration: 9,
      partSize: 8 * 1024 * 1024,
      totalParts: 1,
    })

    setSystemTime(new Date(base + 4 * 60 * 60 * 1000 + 1))
    expect(verifyVideoMultipartSessionToken(token)).toBeNull()
  })
})
