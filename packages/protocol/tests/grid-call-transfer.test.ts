import { describe, expect, test } from "bun:test"
import * as P from "../src/core.js"

const callId = "12121212-3434-4567-89ab-cdcdcdcdcdcd"
const membershipId = "66666666-7777-4888-8999-aaaaaaaaaaaa"

describe("grid call transfer wire contract", () => {
  test("Move keeps its allocation and exact ownership fence through binary encoding", () => {
    expect(P.Method.MOVE_GRID_CALL_HERE).toBe(146)
    expect(P.RpcCall.fields.find((field) => field.localName === "moveGridCallHere")?.no).toBe(147)
    expect(P.RpcResult.fields.find((field) => field.localName === "moveGridCallHere")?.no).toBe(147)

    const call = P.RpcCall.fromJson({
      method: "MOVE_GRID_CALL_HERE",
      moveGridCallHere: { callId, expectedMembershipId: membershipId },
    })
    expect(P.RpcCall.fromBinary(P.RpcCall.toBinary(call))).toEqual(call)

    for (const moved of [false, true]) {
      const result = P.RpcResult.fromJson({
        reqMsgId: "9007199254740993",
        moveGridCallHere: {
          moved,
          grids: [{ spaceId: "9007199254740995", callTransferEnabled: true }],
          currentCall: {
            callId,
            membershipId,
            spaceId: "9007199254740995",
            roomId: "9007199254740997",
            ownedByCurrentSession: moved,
            ownerClientType: "ios",
          },
          ...(moved ? { connection: {
            serverUrl: "wss://fixture.invalid",
            participantIdentity: "fixture-participant",
            token: "public-fixture-token",
            expiresAt: "9007199254740999",
            callId,
            membershipId,
          } } : {}),
        },
      })
      expect(P.RpcResult.fromBinary(P.RpcResult.toBinary(result))).toEqual(result)
      expect(result.result.oneofKind).toBe("moveGridCallHere")
    }
  })

  test("an omitted renewal fence remains distinct from explicit no-presence", () => {
    const legacy = P.GetGridInput.fromJson({ spaceId: "9007199254740995" })
    const expectNoPresence = P.GetGridInput.fromJson({
      spaceId: "9007199254740995",
      expectedMembershipId: "",
    })
    const decodedLegacy = P.GetGridInput.fromBinary(P.GetGridInput.toBinary(legacy))
    const decodedFenced = P.GetGridInput.fromBinary(P.GetGridInput.toBinary(expectNoPresence))
    expect(decodedLegacy.expectedMembershipId).toBeUndefined()
    expect(decodedFenced.expectedMembershipId).toBe("")
    expect(P.GetGridInput.toBinary(legacy)).not.toEqual(P.GetGridInput.toBinary(expectNoPresence))
  })
})
