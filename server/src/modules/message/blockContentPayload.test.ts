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
    const { encryptStoredBlockContent } = await import("./blockContentPayload")
    expect(() =>
      encryptStoredBlockContent({
        text: "x".repeat(512 * 1024),
        blockContent: BlockContent.create({ blocks: [] }),
      }),
    ).toThrow("Binary data exceeds maximum length")
  })
})
