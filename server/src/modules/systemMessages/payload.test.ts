import { beforeEach, describe, expect, it } from "bun:test"
import {
  decryptSystemMessagePayload,
  encryptSystemMessagePayload,
  SystemMessage,
  type SystemMessage as SystemMessagePayload,
} from "./payload"

beforeEach(() => {
  process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
})

describe("SystemMessage payload", () => {
  it("round trips thread backlink payloads", () => {
    const payload: SystemMessagePayload = {
      event: {
        oneofKind: "threadBacklink",
        threadBacklink: { graphLinkId: 42n, sourceChatId: 10n, sourceTitle: "Source" },
      },
    }

    expect(SystemMessage.fromBinary(SystemMessage.toBinary(payload))).toEqual(payload)
    expect(decryptSystemMessagePayload(encryptSystemMessagePayload(payload))).toEqual(payload)
  })

  it("round trips pinned message payloads", () => {
    const payload: SystemMessagePayload = {
      event: {
        oneofKind: "pinnedMessage",
        pinnedMessage: { pinnedMessageGlobalId: 99n, pinnedMessageId: 12n },
      },
    }

    expect(SystemMessage.fromBinary(SystemMessage.toBinary(payload))).toEqual(payload)
    expect(decryptSystemMessagePayload(encryptSystemMessagePayload(payload))).toEqual(payload)
  })
})
