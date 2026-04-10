import { describe, expect, test } from "bun:test"
import { getDocumentMetadataAndValidate } from "@in/server/modules/files/metadata"

describe("getDocumentMetadataAndValidate", () => {
  test("accepts blank MIME types for documents and falls back from extension", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "script.py", {
      type: "",
    })

    const metadata = await getDocumentMetadataAndValidate(file)

    expect(metadata.fileName).toBe("script.py")
    expect(metadata.extension).toBe("py")
    expect(metadata.mimeType).toBe("text/x-python")
  })

  test("maps known non-media extensions like ovpn when MIME is blank", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "config.ovpn", {
      type: "",
    })

    const metadata = await getDocumentMetadataAndValidate(file)

    expect(metadata.extension).toBe("ovpn")
    expect(metadata.mimeType).toBe("application/x-openvpn-profile")
  })

  test("falls back to application/octet-stream for unknown document extensions", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "archive.custombin", {
      type: "",
    })

    const metadata = await getDocumentMetadataAndValidate(file)

    expect(metadata.extension).toBe("custombin")
    expect(metadata.mimeType).toBe("application/octet-stream")
  })

  test("accepts extensionless documents", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "Dockerfile", {
      type: "",
    })

    const metadata = await getDocumentMetadataAndValidate(file)

    expect(metadata.fileName).toBe("Dockerfile")
    expect(metadata.extension).toBe("")
    expect(metadata.mimeType).toBe("application/octet-stream")
  })
})
