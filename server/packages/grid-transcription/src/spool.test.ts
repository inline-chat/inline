import { describe, expect, test } from "bun:test"
import { randomBytes, randomUUID } from "node:crypto"
import { appendFileSync, mkdtempSync, readFileSync, readdirSync, renameSync, utimesSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spoolConfig, TurnSpool } from "./spool.js"

function fixture(maxBytes = 1024 * 1024) {
  const dir = mkdtempSync(join(tmpdir(), "grid-spool-"))
  return { dir, spool: new TurnSpool({ dir, key: randomBytes(32).toString("base64"), maxBytes }) }
}
const frame = (value: number) => new Int16Array(320).fill(value)

describe("encrypted turn spool", () => {
  test("round-trips audio sealed per frame and lists turn state without content", () => {
    const { dir, spool } = fixture()
    const id = randomUUID()
    expect(spool.open(id, "meeting", 16_000)).toBe(true)
    expect(spool.append(id, frame(7))).toBe(true)
    expect(spool.append(id, frame(-3))).toBe(true)
    spool.close(id)
    expect([...spool.read(id)]).toEqual([...frame(7), ...frame(-3)])
    expect(readFileSync(join(dir, `${id}.pcm`)).includes(Buffer.from(frame(7).buffer))).toBe(false)
    expect(spool.list()).toMatchObject([{ segmentId: id, model: "meeting", sampleRate: 16_000, closed: true, handoff: false }])
    spool.handoff(id)
    expect(spool.list()[0]?.handoff).toBe(true)
    spool.remove(id)
    expect(readdirSync(dir)).toEqual([])
  })

  test("a torn final record keeps earlier audio and sealed audio cannot move between turns", () => {
    const { dir, spool } = fixture()
    const id = randomUUID()
    const other = randomUUID()
    spool.open(id, "meeting", 16_000)
    spool.append(id, frame(1))
    appendFileSync(join(dir, `${id}.pcm`), Buffer.from([200, 0, 0, 0, 1, 2, 3]))
    expect([...spool.read(id)]).toEqual([...frame(1)])
    spool.open(other, "meeting", 16_000)
    renameSync(join(dir, `${id}.pcm`), join(dir, `${other}.pcm`))
    expect(() => spool.read(other)).toThrow()
  })

  test("a full spool declines new turns instead of failing capture", () => {
    const { spool } = fixture(2_000)
    const first = randomUUID()
    expect(spool.open(first, "meeting", 16_000)).toBe(true)
    spool.append(first, frame(1))
    spool.append(first, frame(1))
    spool.append(first, frame(1))
    expect(spool.open(randomUUID(), "meeting", 16_000)).toBe(false)
  })

  test("touch refreshes ownership time and invalid identifiers are never opened", () => {
    const { dir, spool } = fixture()
    const id = randomUUID()
    spool.open(id, "standard", 24_000)
    utimesSync(join(dir, `${id}.json`), new Date(0), new Date(0))
    expect(spool.list()[0]?.touchedAtMs).toBe(0)
    spool.touch(id)
    expect(spool.list()[0]!.touchedAtMs).toBeGreaterThan(Date.now() - 5_000)
    expect(spool.open("../escape", "meeting", 16_000)).toBe(false)
  })

  test("configuration needs both an absolute directory and a 32-byte key", () => {
    expect(spoolConfig({})).toBeUndefined()
    const key = randomBytes(32).toString("base64")
    expect(spoolConfig({ GRID_TRANSCRIPTION_SPOOL_DIR: "/data/spool", GRID_TRANSCRIPTION_SPOOL_KEY: key }))
      .toEqual({ dir: "/data/spool", key, maxBytes: 2048 * 1024 * 1024 })
    expect(() => spoolConfig({ GRID_TRANSCRIPTION_SPOOL_DIR: "/data/spool" })).toThrow("protocol")
    expect(() => spoolConfig({ GRID_TRANSCRIPTION_SPOOL_DIR: "relative", GRID_TRANSCRIPTION_SPOOL_KEY: key })).toThrow("protocol")
    expect(() => spoolConfig({ GRID_TRANSCRIPTION_SPOOL_DIR: "/data", GRID_TRANSCRIPTION_SPOOL_KEY: "c2hvcnQ=" })).toThrow("protocol")
  })
})
