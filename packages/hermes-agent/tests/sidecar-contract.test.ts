import { describe, expect, it } from "vitest"
import {
  SidecarError,
  normalizeInboundEvent,
  normalizeError,
  normalizeUploadKind,
  parseOptionalInt,
  parseTarget,
  redactText,
  redactUrl,
  readOptionalBoolean,
  readOptionalNumber,
  readRequiredString,
  safeJson,
} from "../src/sidecar/contract.js"

describe("sidecar contract helpers", () => {
  it("serializes bigint, binary, arrays, and objects into JSON-safe values", () => {
    expect(safeJson({
      id: 123n,
      binary: new Uint8Array([104, 105]),
      bad: Number.NaN,
      skip: undefined,
      nested: [1n, undefined, true],
    })).toEqual({
      id: "123",
      binary: "aGk=",
      bad: null,
      nested: ["1", null, true],
    })
  })

  it("parses explicit chat and user targets", () => {
    expect(parseTarget({ target: { chatId: "42" } })).toEqual({ chatId: 42n })
    expect(parseTarget({ userId: 99 })).toEqual({ userId: 99n })
  })

  it("rejects ambiguous, missing, or invalid targets as bad format", () => {
    expect(() => parseTarget({ target: { chatId: "1", userId: "2" } })).toThrow(SidecarError)
    expect(() => parseTarget({ target: {} })).toThrow(SidecarError)
    expect(() => parseTarget({ chatId: "not-a-number" })).toThrow(SidecarError)
    expect(() => parseTarget({ userId: "0" })).toThrow(SidecarError)

    for (const input of [
      () => parseTarget({ target: { chatId: "1", userId: "2" } }),
      () => parseTarget({ target: {} }),
      () => parseTarget({ chatId: "not-a-number" }),
      () => parseTarget({ userId: "0" }),
    ]) {
      try {
        input()
      } catch (error) {
        expect(error).toBeInstanceOf(SidecarError)
        expect((error as SidecarError).errorKind).toBe("bad_format")
      }
    }
  })

  it("normalizes upload kind from explicit values and file extensions", () => {
    expect(normalizeUploadKind("image", "ignored.bin")).toBe("photo")
    expect(normalizeUploadKind("voice", "ignored.bin")).toBe("document")
    expect(normalizeUploadKind(undefined, "photo.HEIC")).toBe("photo")
    expect(normalizeUploadKind(undefined, "clip.mov")).toBe("video")
    expect(normalizeUploadKind(undefined, "archive.zip")).toBe("document")
  })

  it("normalizes typed and inferred errors for HTTP responses", () => {
    expect(normalizeError(new SidecarError("invalid target", "bad_format")).status).toBe(400)
    expect(normalizeError(new SidecarError("private file", "forbidden")).status).toBe(403)
    expect(normalizeError(new SidecarError("missing chat", "not_found")).status).toBe(404)
    expect(normalizeError(new SidecarError("large file", "too_long")).status).toBe(413)
    expect(normalizeError(new SidecarError("slow down", "rate_limited")).status).toBe(429)
    expect(normalizeError(new SidecarError("network closed", "transient")).status).toBe(503)
    expect(normalizeError(new SidecarError("unexpected", "unknown")).status).toBe(500)
    expect(normalizeError(new Error("rate limit exceeded")).errorKind).toBe("rate_limited")
    expect(normalizeError(new Error("network closed")).errorKind).toBe("transient")
    expect(normalizeError(new Error("unauthorized")).status).toBe(403)
    expect(normalizeError(new Error("weird failure")).errorKind).toBe("unknown")
  })

  it("redacts configured secrets without treating empty secrets as matches", () => {
    expect(redactText("token before inline-secret after", [
      { value: "", label: "[EMPTY]" },
      { value: undefined, label: "[UNDEFINED]" },
      { value: "inline-secret", label: "[INLINE_TOKEN]" },
    ])).toBe("token before [INLINE_TOKEN] after")
    expect(redactText(new Error("sidecar-secret failed"), [
      { value: "sidecar-secret", label: "[INLINE_SIDECAR_TOKEN]" },
    ])).toBe("[INLINE_SIDECAR_TOKEN] failed")
  })

  it("redacts credentials and token-like URL parameters", () => {
    expect(redactUrl("http://user:pass@127.0.0.1/mock?token=secret&apiToken=also-secret&ok=1"))
      .toBe("http://redacted:redacted@127.0.0.1/mock?token=redacted&apiToken=redacted&ok=1")
    expect(redactUrl("not a url")).toBe("not a url")
  })

  it("normalizes message inbound events into the Python adapter contract", () => {
    expect(normalizeInboundEvent({
      kind: "message.new",
      chatId: 10n,
      seq: 7,
      date: 123n,
      message: {
        id: 99n,
        fromId: 42n,
        chatId: 10n,
        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
        message: "hello",
        out: false,
        mentioned: true,
        replyToMsgId: 88n,
        date: 123n,
        replies: { chatId: 11n },
        media: { media: { oneofKind: "photo", photo: { photoId: 5n } } },
      },
    }, "1600")).toEqual({
      kind: "message.new",
      chatId: "10",
      seq: 7,
      date: "123",
      meId: "1600",
      message: {
        id: "99",
        fromId: "42",
        chatId: "10",
        peerId: { type: { oneofKind: "chat", chat: { chatId: "10" } } },
        message: "hello",
        out: false,
        mentioned: true,
        replyToMsgId: "88",
        date: "123",
        entities: null,
        media: { media: { oneofKind: "photo", photo: { photoId: "5" } } },
        attachments: null,
        reactions: null,
        replies: { chatId: "11" },
        actions: null,
        rev: null,
        raw: {
          id: "99",
          fromId: "42",
          chatId: "10",
          peerId: { type: { oneofKind: "chat", chat: { chatId: "10" } } },
          message: "hello",
          out: false,
          mentioned: true,
          replyToMsgId: "88",
          date: "123",
          replies: { chatId: "11" },
          media: { media: { oneofKind: "photo", photo: { photoId: "5" } } },
        },
      },
    })
  })

  it("normalizes action callback data to base64", () => {
    expect(normalizeInboundEvent({
      kind: "message.action.invoke",
      interactionId: 1n,
      chatId: 2n,
      messageId: 3n,
      actorUserId: 4n,
      actionId: "cl:abc:0",
      data: new Uint8Array([99, 108]),
      seq: 8,
      date: 9n,
    }, "1600")).toEqual({
      kind: "message.action.invoke",
      interactionId: "1",
      chatId: "2",
      messageId: "3",
      actorUserId: "4",
      actionId: "cl:abc:0",
      data: "Y2w=",
      dataBase64: "Y2w=",
      seq: 8,
      date: "9",
      meId: "1600",
    })
  })

  it("reads primitive request fields conservatively", () => {
    const record = {
      text: " hello ",
      enabled: "yes",
      disabled: "0",
      limit: "12",
      badLimit: "x",
    }
    expect(readRequiredString(record, "text")).toBe("hello")
    expect(readOptionalBoolean(record, "enabled")).toBe(true)
    expect(readOptionalBoolean(record, "disabled")).toBe(false)
    expect(readOptionalNumber(record, "limit")).toBe(12)
    expect(readOptionalNumber(record, "badLimit")).toBeUndefined()
    expect(parseOptionalInt("8794")).toBe(8794)
    expect(parseOptionalInt(" 8794 ")).toBe(8794)
    expect(parseOptionalInt("8794ms")).toBeUndefined()
    expect(parseOptionalInt("")).toBeUndefined()
  })
})
