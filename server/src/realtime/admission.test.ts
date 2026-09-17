import { describe, expect, it } from "bun:test"
import { Method } from "@inline-chat/protocol/core"
import { admitPreauthMessage, makeConnectionAdmission, PREAUTH_METHODS } from "./admission"

describe("realtime admission", () => {
  it("enforces process and IP capacity, releases once, and bounds reconnect rate", () => {
    const admission = makeConnectionAdmission({ total: 2, perIp: 1, upgradesPerMinute: 2 })
    const first = admission.acquire("a", 0)!
    expect(first.activate()).toBe(true)
    expect(admission.acquire("a", 0)).toBeUndefined()
    const second = admission.acquire("b", 0)!
    expect(admission.acquire("c", 0)).toBeUndefined()
    first.release(); first.release()
    admission.acquire("a", 0)!.release()
    expect(admission.acquire("a", 0)).toBeUndefined()
    admission.acquire("a", 60_000)!.release()
    second.release()
    admission.shutdown()
  })

  it("allows only the existing public profile methods before authentication", () => {
    expect([...PREAUTH_METHODS]).toEqual([Method.GET_USERS, Method.SEARCH_USERS])
    expect(PREAUTH_METHODS.has(Method.SEND_MESSAGE)).toBe(false)
  })

  it("prevents parallel initializations and bounds retries without letting pings release the guard", () => {
    const connection = {}
    const release = admitPreauthMessage(connection, false, true)!
    admitPreauthMessage(connection, false, false)!()
    expect(admitPreauthMessage(connection, false, true)).toBeUndefined()
    release()
    admitPreauthMessage(connection, false, true)!()
    admitPreauthMessage(connection, false, true)!()
    expect(admitPreauthMessage(connection, false, true)).toBeUndefined()
    expect(admitPreauthMessage(connection, true, false)).toBeFunction()
  })
})
