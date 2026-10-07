import { describe, expect, test } from "bun:test"
import * as P from "../src/core.js"

// Distinct payloads protect field numbers, oneof dispatch, nested values,
// optional false and int64 values beyond JavaScript number precision.
const cases = [
  {
    method: "OPEN_GRID_THREAD",
    field: "openGridThread",
    value: 147,
    tag: 148,
    request: {
      roomId: "9007199254740995",
      expectedMembershipId: "66666666-7777-4888-8999-aaaaaaaaaaaa"
    },
    result: {
      chatId: "9007199254740997"
    }
  },
  {
    method: "SET_GRID_TRANSCRIPTION",
    field: "setGridTranscription",
    value: 148,
    tag: 149,
    request: {
      roomId: "9007199254740995",
      expectedMembershipId: "66666666-7777-4888-8999-aaaaaaaaaaaa",
      expectedGeneration: 23,
      expectedRunId: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
      expectedRevision: 37,
      enabled: true,
      destination: "GRID_TRANSCRIPT_EXISTING",
      transcriptChatId: "9007199254740997",
      requestId: "12121212-3434-4567-89ab-cdcdcdcdcdcd"
    },
    result: {
      grid: {
        spaceId: "9007199254740993",
        enabled: true,
        currentRoomId: "9007199254740995",
        revision: "9007199254740999",
        rooms: [
          {
            id: "9007199254740995",
            spaceId: "9007199254740993",
            roomThreadId: "9007199254741001",
            transcriptionAvailable: true,
            transcription: {
              runId: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
              state: "GRID_TRANSCRIPTION_STOPPING",
              transcriptChatId: "9007199254740997",
              revision: 37
            }
          }
        ]
      }
    }
  },
  {
    method: "LIST_GRID_TRANSCRIPTS",
    field: "listGridTranscripts",
    value: 149,
    tag: 150,
    request: {
      roomId: "9007199254740995"
    },
    result: {
      transcripts: [
        {
          transcriptChatId: "9007199254740997",
          title: "Planning discussion",
          busy: true
        },
        {
          transcriptChatId: "9007199254741003",
          title: "Earlier session",
          busy: false
        }
      ]
    }
  }
] as const

describe("grid transcription allocation", () => {
  for (const { method, field, value, tag, request, result } of cases) {
    test(`${method} request and result binary round trip`, () => {
      expect(P.Method[method]).toBe(value)
      expect(P.RpcCall.fields.find((f) => f.localName === field)?.no).toBe(tag)
      expect(P.RpcResult.fields.find((f) => f.localName === field)?.no).toBe(tag)
      const call = P.RpcCall.fromJson({ method, [field]: request })
      expect(call.input.oneofKind).toBe(field)
      const decodedCall = P.RpcCall.fromBinary(P.RpcCall.toBinary(call))
      expect(decodedCall).toEqual(call)
      expect(P.RpcCall.toJsonString(decodedCall)).toEqual(P.RpcCall.toJsonString(call))
      const response = P.RpcResult.fromJson({ reqMsgId: "9007199254740993", [field]: result })
      expect(response.result.oneofKind).toBe(field)
      const decodedResult = P.RpcResult.fromBinary(P.RpcResult.toBinary(response))
      expect(decodedResult).toEqual(response)
      expect(P.RpcResult.toJsonString(decodedResult)).toEqual(P.RpcResult.toJsonString(response))
    })
  }
  test("both namespaces stay unique and previous methods survive", () => {
    for (const type of [P.RpcCall, P.RpcResult]) {
      const tags = type.fields.map((f) => f.no)
      expect(new Set(tags).size).toBe(tags.length)
    }
    expect(P.Method.GET_GRID).toBe(83)
    expect(P.Method.SEARCH_MESSAGES).toBe(28)
    expect(P.ConnectionInit.fields.some((f) => f.localName === "supportsWorking")).toBe(true)
  })
})
