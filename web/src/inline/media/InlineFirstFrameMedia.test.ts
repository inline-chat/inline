import { DbObjectKind, type User } from "@inline/client/core"
import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import type { InlineMediaRepository } from "./InlineMediaRepository"
import {
  inlineAvatarMediaDescriptor,
  promoteInlineFirstFrameMedia,
} from "./InlineFirstFrameMedia"

describe("Inline first-frame media", () => {
  it("uses the same stable avatar identity as UserAvatar", () => {
    const user: User = {
      kind: DbObjectKind.User,
      id: userId(7),
      profilePhoto: {
        fileUniqueId: "avatar:stable",
        cdnUrl: "https://cdn.inline.chat/rotating-signed-url",
      },
    }

    expect(inlineAvatarMediaDescriptor(user)).toEqual({
      key: "avatar:stable",
    })
  })

  it("deduplicates keys and isolates one corrupt cache entry", async () => {
    const promoteCached = vi.fn(async (key: string) => {
      if (key === "broken") throw new Error("corrupt cache entry")
      return key === "cached"
    })
    const repository = {
      promoteCached,
    } as unknown as InlineMediaRepository

    await expect(
      promoteInlineFirstFrameMedia(repository, [
        { key: "cached" },
        { key: "cached" },
        { key: "missing" },
        { key: "broken" },
        undefined,
      ]),
    ).resolves.toBe(1)
    expect(promoteCached.mock.calls.map(([key]) => key)).toEqual([
      "cached",
      "missing",
      "broken",
    ])
  })
})
