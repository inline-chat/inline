import { describe, expect, test } from "bun:test"
import { uploadToBucket } from "./uploadToBucket"

describe("file object storage writes", () => {
  test("rejects a short permanent-object write", async () => {
    const file = new File([new Uint8Array([1, 2, 3])], "proof.bin")
    await expect(uploadToBucket(file, {
      path: "native-uploads/v1/proof",
      type: "application/octet-stream",
    }, async () => 2)).rejects.toThrow("wrote 2 of 3 bytes")
  })
})
