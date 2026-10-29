import { describe, expect, test } from "bun:test"
import { randomBytes, randomUUID } from "node:crypto"
import { mkdtempSync, utimesSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { SpoolRecovery } from "./recovery.js"
import { TurnSpool } from "./spool.js"

function fixture(options: { fail?: () => boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "grid-recovery-"))
  const spool = new TurnSpool({ dir, key: randomBytes(32).toString("base64"), maxBytes: 1024 * 1024 })
  const late: { segmentId: string; text: string }[] = []
  const transcribed: string[] = []
  let clock = Date.now()
  const recovery = new SpoolRecovery({
    spool, now: () => clock, staleMs: 60_000,
    apiKey: (model) => model === "meeting" ? "soniox-key" : undefined,
    transcribe: async (_model, _key, samples) => {
      if (options.fail?.()) throw new Error("provider down")
      transcribed.push(String(samples.length))
      return `${samples.length} samples`
    },
    api: { async late(segmentId, text) { late.push({ segmentId, text }) } },
  })
  const add = (handoff: boolean, ageMs = 0) => {
    const id = randomUUID()
    spool.open(id, "meeting", 16_000)
    spool.append(id, new Int16Array(320))
    if (handoff) spool.handoff(id)
    else spool.close(id)
    const touched = new Date(clock - ageMs)
    utimesSync(join(dir, `${id}.json`), touched, touched)
    return id
  }
  return { spool, recovery, late, transcribed, add, advance(ms: number) { clock += ms } }
}

describe("spool recovery", () => {
  test("handed-off and abandoned turns become late finals; turns a live owner refreshes stay", async () => {
    const value = fixture()
    const handed = value.add(true)
    const abandoned = value.add(false, 61_000)
    const owned = value.add(false, 5_000)
    await value.recovery.drain()
    expect(value.late.map((turn) => turn.segmentId).sort()).toEqual([abandoned, handed].sort())
    expect(value.late[0]?.text).toBe("320 samples")
    expect(value.spool.list().map((turn) => turn.segmentId)).toEqual([owned])
  })

  test("an unreachable provider keeps the audio and retries with backoff", async () => {
    let down = true
    const value = fixture({ fail: () => down })
    const id = value.add(true)
    await value.recovery.drain()
    expect(value.late).toEqual([])
    expect(value.spool.list()).toHaveLength(1)
    down = false
    await value.recovery.drain()
    expect(value.late).toEqual([])
    value.advance(31_000)
    await value.recovery.drain()
    expect(value.late.map((turn) => turn.segmentId)).toEqual([id])
    expect(value.spool.list()).toEqual([])
  })

  test("speech older than the late-final window is deleted unsent", async () => {
    const value = fixture()
    value.add(true)
    value.advance(25 * 60 * 60 * 1000)
    await value.recovery.drain()
    expect(value.late).toEqual([])
    expect(value.transcribed).toEqual([])
    expect(value.spool.list()).toEqual([])
  })
})
