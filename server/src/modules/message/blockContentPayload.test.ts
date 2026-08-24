import { BlockContent } from "@inline-chat/protocol/core"
import { beforeAll, describe, expect, test } from "bun:test"

beforeAll(() => {
  process.env["ENCRYPTION_KEY"] ??= "a".repeat(64)
})

describe("stored block content encryption", () => {
  test("round trips through the dedicated rich-content boundary", async () => {
    const { decryptStoredBlockContent, encryptStoredBlockContent } = await import("./blockContentPayload")
    const blockContent = BlockContent.create({
      blocks: [
        {
          kind: {
            oneofKind: "paragraph",
            paragraph: { offset: 0n, length: 5n },
          },
        },
      ],
    })

    const encrypted = encryptStoredBlockContent({ text: "hello", blockContent })
    expect(decryptStoredBlockContent(encrypted)).toEqual({
      text: "hello",
      entities: undefined,
      blockContent,
    })
  })

  test("does not raise the ordinary 20 KB encryption ceiling", async () => {
    const { encryptBinary } = await import("@in/server/modules/encryption/encryption")
    const { encryptStoredBlockContent } = await import("./blockContentPayload")
    const text = "x".repeat(21_000)

    expect(() => encryptBinary(Buffer.from(text))).toThrow("Binary data exceeds maximum length")
    expect(() =>
      encryptStoredBlockContent({
        text,
        blockContent: BlockContent.create({ blocks: [] }),
      }),
    ).not.toThrow()
  })

  test("rejects a canonical payload beyond 512 KiB", async () => {
    const { assertStoredBlockContentPayloadFits, encryptStoredBlockContent } = await import("./blockContentPayload")
    const oversized = {
      text: "x".repeat(512 * 1024),
      blockContent: BlockContent.create({ blocks: [] }),
    }
    expect(() => assertStoredBlockContentPayloadFits(oversized)).toThrow(
      "Binary data exceeds maximum length",
    )
    expect(() =>
      encryptStoredBlockContent(oversized),
    ).toThrow("Binary data exceeds maximum length")
  })

  test("rejects oversized preparation before entering the storage transaction", async () => {
    const { prepareBlockContent } = await import("./blockContentStorage")
    expect(() => prepareBlockContent({
      text: "x".repeat(512 * 1024),
      parsed: {
        blockContent: BlockContent.create({ blocks: [] }),
        imageSources: [],
      },
    })).toThrow("Binary data exceeds maximum length")
  })

  test("classifies corrupt stored ciphertext separately from encryption configuration", async () => {
    const {
      decryptStoredBlockContent,
      encryptStoredBlockContent,
      StoredBlockContentPayloadError,
    } = await import("./blockContentPayload")
    const encrypted = encryptStoredBlockContent({
      text: "hello",
      blockContent: BlockContent.create({ blocks: [] }),
    })

    expect(() => decryptStoredBlockContent({
      ...encrypted,
      authTag: Buffer.alloc(encrypted.authTag.length),
    })).toThrow(StoredBlockContentPayloadError)
  })

  test("does not quarantine an oversized payload while encryption is misconfigured", async () => {
    const { EncryptionConfigurationError } = await import("@in/server/modules/encryption/encryption")
    const { decryptStoredBlockContent, maxStoredBlockContentBytes } = await import("./blockContentPayload")
    const previousKey = process.env["ENCRYPTION_KEY"]
    process.env["ENCRYPTION_KEY"] = "invalid"

    try {
      expect(() => decryptStoredBlockContent({
        encrypted: Buffer.alloc(maxStoredBlockContentBytes + 1),
        iv: Buffer.alloc(12),
        authTag: Buffer.alloc(16),
      })).toThrow(EncryptionConfigurationError)
    } finally {
      if (previousKey === undefined) {
        delete process.env["ENCRYPTION_KEY"]
      } else {
        process.env["ENCRYPTION_KEY"] = previousKey
      }
    }
  })
})
