import type { MessageRow, ServiceContent } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { forwardHeaderModel, repliesSummaryModel, sameVia, viaModel } from "./headers"
import { isTranscriptSpeech, serviceFallbackText, serviceRowModel } from "./service"

const row = (service: ServiceContent, extra: Partial<MessageRow> = {}) => ({
  id: "5:40",
  service,
  out: false,
  fromId: "7" as UserID,
  text: "",
  ...extra,
})

describe("service rows", () => {
  it("words a thread backlink with and without a title", () => {
    const model = serviceRowModel(row({ kind: "threadBacklink", sourceChatId: "12" as ChatID, sourceTitle: " Launch " }), { sender: "Ada" })
    expect(model?.text).toBe("Ada linked from [[Launch]]")
    expect(model?.segments.map((segment) => segment.tone)).toEqual(["secondary", "secondary", "tertiary", "secondary", "tertiary"])
    expect(model?.segments[0]?.link).toEqual({ kind: "user", userId: "7" })
    expect(model?.segments[3]?.link).toEqual({ kind: "thread", chatId: "12" })
    expect(model?.target).toEqual({ kind: "thread", chatId: "12" })
    expect(serviceRowModel(row({ kind: "threadBacklink" }), {})?.text).toBe("Someone linked to this thread")
    expect(serviceRowModel(row({ kind: "threadBacklink" }, { out: true }), { sender: "Ada" })?.text).toBe("You linked to this thread")
  })

  it("words a pinned message and points at it", () => {
    const model = serviceRowModel(row({ kind: "pinnedMessage", messageId: "3" as MessageID }), { sender: "Ada" })
    expect(model?.text).toBe("Ada pinned a message")
    expect(model?.target).toEqual({ kind: "message", messageId: "3" })
  })

  it("renders transcripts, and leaves the sender's own speech to the timeline", () => {
    const turn = serviceRowModel(
      row({ kind: "gridTranscript", runId: "r", segmentId: "s", speakerUserId: "8" as UserID, event: "turn" }, { text: "Transcript · Hello" }),
    )
    expect(turn?.segments).toEqual([
      { text: "Transcript · ", tone: "tertiary" },
      { text: "Hello", tone: "primary" },
    ])
    expect(turn?.align).toBe("start")
    const own = row({ kind: "gridTranscript", runId: "r", segmentId: "s", speakerUserId: "7" as UserID, event: "turn" })
    expect(isTranscriptSpeech(own)).toBe(true)
    expect(serviceRowModel(own)).toBeUndefined()
    const status = serviceRowModel(
      row(
        { kind: "gridTranscript", runId: "r", segmentId: "s", event: "link" },
        { text: "Moved to Design", entities: [{ type: "thread", offset: 9, length: 6, chatId: "4" as ChatID }] },
      ),
    )
    expect(status?.segments).toEqual([
      { text: "Moved to ", tone: "secondary" },
      { text: "Design", tone: "secondary", link: { kind: "thread", chatId: "4" } },
    ])
  })

  it("shows an unknown event's text, and has preview fallbacks", () => {
    expect(serviceRowModel(row({ kind: "unknown" }, { text: "Something happened" }))?.text).toBe("Something happened")
    expect(serviceRowModel({ ...row({ kind: "unknown" }), service: undefined })).toBeUndefined()
    expect(serviceFallbackText({ service: { kind: "threadBacklink", sourceTitle: "X" }, text: "" })).toBe("Linked from X")
    expect(serviceFallbackText({ service: { kind: "threadBacklink" }, text: "" })).toBe("Linked from another thread")
    expect(serviceFallbackText({ service: { kind: "pinnedMessage" }, text: "" })).toBe("Pinned a message")
  })
})

describe("headers", () => {
  it("words the forward header and its target", () => {
    expect(
      forwardHeaderModel({ fromPeer: { kind: "chat", chatId: "9" as ChatID }, fromMessageId: "2" as MessageID }, { title: "Design" }),
    ).toEqual({ text: "Forwarded from: Design", target: { kind: "chat", chatId: "9", messageId: "2" } })
    expect(forwardHeaderModel({ fromUserId: "8" as UserID })).toEqual({
      text: "Forwarded from a private chat",
      target: { kind: "user", userId: "8", messageId: undefined },
    })
    // A forward of my own message goes to the peer.
    expect(
      forwardHeaderModel({ fromPeer: { kind: "user", userId: "8" as UserID }, fromUserId: "7" as UserID }, { me: "7" as UserID, title: "Bo" })
        .target,
    ).toEqual({ kind: "user", userId: "8", messageId: undefined })
  })

  it("words via like the Mac", () => {
    expect(viaModel({ kind: "app", app: "claude-code", name: "Claude Code" }, { sender: "Ada" })).toMatchObject({
      label: "Sent via Claude Code",
      tooltip: "Ada sent this using Claude Code, an AI agent.",
    })
    expect(viaModel({ kind: "app", app: "agent" })).toMatchObject({
      label: "Sent via an AI agent",
      tooltip: "The sender sent this using an AI agent.",
    })
    expect(viaModel({ kind: "bot", botUserId: "30" as UserID, name: "Old" }, { botName: "Scout" })).toMatchObject({
      label: "Sent via Scout",
      tooltip: "The sender sent this using their bot Scout.",
    })
    expect(viaModel({ kind: "bot", botUserId: "30" as UserID }).label).toBe("Sent via a bot")
    expect(sameVia({}, {})).toBe(true)
    expect(sameVia({ via: { kind: "app", app: "codex" } }, {})).toBe(false)
    expect(sameVia({ via: { kind: "app", app: "codex", name: "A" } }, { via: { kind: "app", app: "codex" } })).toBe(true)
  })

  it("words the reply summary and hides what the Mac hides", () => {
    const base = { chatId: "77" as ChatID, hasUnread: true, recentUserIds: ["1", "2", "3", "4"] as UserID[] }
    expect(repliesSummaryModel({ ...base, kind: "reply", count: 1 })?.label).toBe("1 reply")
    expect(repliesSummaryModel({ ...base, kind: "reply", count: 1200 }, "en")).toMatchObject({ label: "1,200 replies", avatars: ["1", "2", "3"], height: 30 })
    expect(repliesSummaryModel({ ...base, kind: "reply", count: 0 })).toBeUndefined()
    expect(repliesSummaryModel({ ...base, kind: "subthread", count: 1, title: "Design" })).toMatchObject({
      label: "Subthread · 1 message",
      height: 46,
    })
    expect(repliesSummaryModel({ ...base, kind: "subthread", count: 3 })).toBeUndefined()
  })
})
