import { describe, expect, test } from "bun:test"
import { TrackWorker, type SpeechConnection, type TrackWorkerOptions } from "./track-worker.js"
import { TranscriptionError, type FinalTurn } from "./protocol.js"
import type { ProviderOptions } from "./socket.js"

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}
const tick = () => new Promise<void>((resolve) => setImmediate(resolve))
async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 100; count++) { if (predicate()) return; await tick() }
  throw new Error("test event did not occur")
}
async function eventually(predicate: () => boolean): Promise<void> {
  for (let waited = 0; waited < 3_000; waited += 5) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 5)) }
  throw new Error("test event did not occur")
}
async function spokenTurn(value: ReturnType<typeof fixture>): Promise<void> {
  const committedBefore = value.commits.length
  value.worker.push(frame(true))
  for (let index = 0; index < 28; index++) value.worker.push(frame(false))
  await eventually(() => value.commits.length > committedBefore || value.failures.length > 0)
}
function fixture(overrides: Partial<TrackWorkerOptions> = {}) {
  let microphone = true
  let authority = true
  let options: ProviderOptions | undefined
  let nextId = 0
  const events: string[] = []
  const audio: number[][] = []
  const commits: string[] = []
  const finals: FinalTurn[] = []
  const failures: TranscriptionError[] = []
  const connection: SpeechConnection = {
    appendAudio(frame) { audio.push([...frame]); events.push("audio") },
    commitTurn(id) { commits.push(id); events.push("commit") }, close() { events.push("close") },
  }
  const worker = new TrackWorker({ model: "meeting", apiKey: "test-key", participantIdentity: "speaker-1", trackSid: "TR_test",
    api: { async admit() { events.push("admit"); return `segment-${++nextId}` },
      async final(turnId, text) { finals.push({ turnId, text }); events.push("final") } },
    detector: { async probability(frame) { return frame[0] === 1 ? 1 : 0 }, close() { events.push("detector-close") } },
    assertRunAuthority() { if (!authority) throw new TranscriptionError("expired") },
    assertMicrophone() { if (!microphone) throw new TranscriptionError("stopped") },
    onFailure(error) { failures.push(error) },
    async connect(value) { options = value; events.push("connect"); return connection }, ...overrides,
  })
  const value = { worker, connection, events, audio, commits, finals, failures,
    get options() { return options }, set options(next: ProviderOptions | undefined) { options = next },
    final(turnId: string, text: string) { options?.onFinal({ turnId, text }) },
    dropSocket() { options?.onFailure(new TranscriptionError("provider")) },
    revokeMicrophone() { microphone = false }, revokeRun() { authority = false } }
  return value
}
function frame(speech: boolean): Int16Array { const data = new Int16Array(320); data[0] = speech ? 1 : 0; return data }
async function utterance(value: ReturnType<typeof fixture>): Promise<void> {
  const committedBefore = value.commits.length
  value.worker.push(frame(true))
  for (let index = 0; index < 28; index++) value.worker.push(frame(false))
  await until(() => value.commits.length > committedBefore || value.failures.length > 0)
  await tick()
}

describe("per microphone finite turn owner", () => {
  test("a drained socket rotates at its age bound without replaying an admitted turn", async () => {
    let clock = 0
    const value = fixture({ now: () => clock })
    await utterance(value)
    clock = 9 * 60 * 1000
    value.final("segment-1", "First completed turn.")
    await until(() => value.finals.length === 1)
    await utterance(value)
    await until(() => value.commits.length === 2)
    expect(value.events.filter((event) => event === "connect")).toHaveLength(2)
    expect(value.events.indexOf("close")).toBeLessThan(value.events.lastIndexOf("connect"))
    expect(value.commits).toEqual(["segment-1", "segment-2"])
    await value.worker.stop(false)
  })
  test("a quiet speaker's socket closes after the idle window and reopens on their next turn", async () => {
    const value = fixture({ idleCloseMs: 30 })
    await utterance(value)
    value.final("segment-1", "Before the pause.")
    await until(() => value.finals.length === 1)
    expect(value.events).not.toContain("close")
    await new Promise((resolve) => setTimeout(resolve, 60))
    expect(value.events.filter((event) => event === "close")).toHaveLength(1)
    await utterance(value)
    await until(() => value.commits.length === 2)
    expect(value.events.filter((event) => event === "connect")).toHaveLength(2)
    expect(value.events.lastIndexOf("connect")).toBeLessThan(value.events.lastIndexOf("audio"))
    await value.worker.stop(false)
  })
  test("provider refusals retry with backoff until a socket opens, without losing the turn", async () => {
    let attempts = 0
    const value = fixture({ retryBaseMs: 5, connect: async (options) => {
      if (++attempts <= 4) throw new TranscriptionError("provider")
      value.events.push("connect")
      value.options = options
      return value.connection
    } })
    await spokenTurn(value)
    expect(attempts).toBe(5)
    expect(value.commits).toEqual(["segment-1"])
    value.final("segment-1", "Survived the outage.")
    await eventually(() => value.finals.length === 1)
    expect(value.failures).toEqual([])
    await value.worker.stop(false)
  })
  test("a dropped socket resends every unfinished turn on a fresh one", async () => {
    const value = fixture({ retryBaseMs: 5 })
    await spokenTurn(value)
    await spokenTurn(value)
    expect(value.commits).toEqual(["segment-1", "segment-2"])
    value.dropSocket()
    await eventually(() => value.commits.length === 4)
    expect(value.commits).toEqual(["segment-1", "segment-2", "segment-1", "segment-2"])
    value.final("segment-1", "First.")
    value.final("segment-2", "Second.")
    await eventually(() => value.finals.length === 2)
    expect(value.finals.map((turn) => turn.turnId)).toEqual(["segment-1", "segment-2"])
    expect(value.failures).toEqual([])
    await value.worker.stop(false)
  })
  test("a turn the provider keeps failing is retired empty and the speaker continues", async () => {
    const value = fixture({ retryBaseMs: 1 })
    await spokenTurn(value)
    for (let drop = 0; drop < 5; drop++) {
      const before = value.commits.length
      value.dropSocket()
      if (drop < 4) await eventually(() => value.commits.length > before)
    }
    await eventually(() => value.finals.length === 1)
    expect(value.finals).toEqual([{ turnId: "segment-1", text: "" }])
    await spokenTurn(value)
    value.final("segment-2", "Next turn still lands.")
    await eventually(() => value.finals.length === 2)
    expect(value.failures).toEqual([])
    await value.worker.stop(false)
  })
  test("spooled speech is removed after its final lands and handed to batch when the provider stays down", async () => {
    const spooled = new Map<string, { frames: number; closed: boolean; handoff: boolean }>()
    const spool = {
      open(id: string) { spooled.set(id, { frames: 0, closed: false, handoff: false }); return true },
      append(id: string) { spooled.get(id)!.frames++; return true },
      close(id: string) { spooled.get(id)!.closed = true },
      handoff(id: string) { spooled.get(id)!.handoff = true },
      touch() {}, remove(id: string) { spooled.delete(id) },
    }
    let providerUp = true
    const value = fixture({ spool, retryBaseMs: 5, batchAfterMs: 50, connect: async (options) => {
      if (!providerUp) throw new TranscriptionError("provider")
      value.events.push("connect")
      value.options = options
      return value.connection
    } })
    await spokenTurn(value)
    expect(spooled.get("segment-1")).toMatchObject({ closed: true, handoff: false })
    value.final("segment-1", "Delivered live.")
    await eventually(() => !spooled.has("segment-1"))
    providerUp = false
    value.dropSocket()
    value.worker.push(frame(true))
    for (let index = 0; index < 28; index++) value.worker.push(frame(false))
    await eventually(() => spooled.get("segment-2")?.handoff === true)
    expect(spooled.get("segment-2")?.frames).toBeGreaterThan(0)
    expect(value.finals.map((turn) => turn.turnId)).toEqual(["segment-1"])
    expect(value.failures).toEqual([])
    await value.worker.stop(false)
    expect(spooled.has("segment-2")).toBe(true)
  })
  test("batch handoff resets a partially replayed socket before the next live turn", async () => {
    let clock = 0
    const gate = deferred<void>()
    const handed: string[] = []
    const value = fixture({ now: () => clock, spool: {
      open() { return true }, append() { return true }, close() {}, touch() {}, remove() {},
      handoff(id) { handed.push(id) },
    }, connect: async (options) => {
      await gate.promise
      value.options = options
      value.events.push("connect")
      return value.connection
    } })
    for (let batch = 0; batch < 3; batch++) {
      for (let index = 0; index < 50; index++) value.worker.push(frame(true))
      await tick()
    }
    for (let index = 0; index < 28; index++) value.worker.push(frame(false))
    await tick()
    clock = 59_000
    gate.resolve()
    await eventually(() => value.audio.length > 0)
    expect(value.commits).toEqual([])
    clock = 61_000
    await eventually(() => handed.length > 0)
    expect(handed).toEqual(["segment-1"])
    expect(value.events).toContain("close")
    await utterance(value)
    expect(value.events.filter((event) => event === "connect")).toHaveLength(2)
    expect(value.commits).toEqual(["segment-2"])
    await value.worker.stop(false)
  })

  test("back-to-back turns inside the idle window reuse one socket", async () => {
    const value = fixture({ idleCloseMs: 1_000 })
    await utterance(value)
    value.final("segment-1", "First.")
    await until(() => value.finals.length === 1)
    await utterance(value)
    value.final("segment-2", "Second.")
    await until(() => value.finals.length === 2)
    expect(value.events.filter((event) => event === "connect")).toHaveLength(1)
    expect(value.events).not.toContain("close")
    await value.worker.stop(false)
  })
  test("a non-cancellable inference promise fails boundedly even without more room audio", async () => {
    const failed = deferred<TranscriptionError>()
    const inference = deferred<number>()
    const value = fixture({ detector: { probability: () => inference.promise, close() {} }, onFailure: failed.resolve })
    value.worker.push(frame(true))
    expect((await failed.promise).code).toBe("audio")
    expect(value.audio).toHaveLength(0)
    expect(value.events).not.toContain("admit")
    await value.worker.stop(false)
  }, 12_000)
  test("API admission precedes every first provider byte; finals retain admitted ID", async () => {
    const value = fixture()
    await utterance(value)
    expect(value.events.slice(0, 3)).toEqual(["admit", "connect", "audio"])
    expect(value.commits).toEqual(["segment-1"])
    value.final("segment-1", "Meeting sentence.")
    await until(() => value.finals.length === 1)
    expect(value.finals).toEqual([{ turnId: "segment-1", text: "Meeting sentence." }])
    await value.worker.stop(false)
    expect(value.failures).toEqual([])
  })

  test("capture continues while final persistence waits; graceful Stop drains finals in order", async () => {
    const first = deferred<void>()
    const attempts: string[] = []
    const saved: FinalTurn[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId, text) {
        attempts.push(turnId)
        if (turnId === "segment-1") await first.promise
        saved.push({ turnId, text })
      },
    } })
    await utterance(value)
    value.final("segment-1", "First phrase.")
    await utterance(value)
    expect(value.commits).toEqual(["segment-1", "segment-2"])
    value.final("segment-2", "Second phrase.")
    await tick()
    expect(attempts).toEqual(["segment-1"])
    expect(saved).toEqual([])
    let drained = false
    const stopping = value.worker.stop(true).then(() => { drained = true })
    await tick()
    expect(drained).toBe(false)
    first.resolve()
    await stopping
    expect(saved).toEqual([
      { turnId: "segment-1", text: "First phrase." },
      { turnId: "segment-2", text: "Second phrase." },
    ])
    expect(value.events).toContain("close")
    expect(value.failures).toEqual([])
  })

  test("destructive Stop interrupts graceful draining before a queued successor reaches the API", async () => {
    const first = deferred<void>()
    const attempts: string[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId) { attempts.push(turnId); await first.promise },
    } })
    await utterance(value)
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.final("segment-2", "Discard this queued phrase.")
    const stopping = value.worker.stop(true)
    await tick()
    await value.worker.stop(false)
    first.resolve()
    await stopping
    await tick(); await tick()
    expect(attempts).toEqual(["segment-1"])
    expect(value.failures).toEqual([])
  })

  test("a lost first response retries the same final before posting its successor", async () => {
    const first = deferred<void>()
    const attempts: FinalTurn[] = []
    const saved: FinalTurn[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId, text) {
        attempts.push({ turnId, text })
        if (attempts.length === 1) { await first.promise; throw new TranscriptionError("provider") }
        saved.push({ turnId, text })
      },
    } })
    await utterance(value)
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.final("segment-2", "Second phrase.")
    await tick()
    expect(attempts).toEqual([{ turnId: "segment-1", text: "First phrase." }])
    const stopping = value.worker.stop(true)
    first.resolve()
    await stopping
    expect(attempts).toEqual([
      { turnId: "segment-1", text: "First phrase." },
      { turnId: "segment-1", text: "First phrase." },
      { turnId: "segment-2", text: "Second phrase." },
    ])
    expect(saved.map((turn) => turn.turnId)).toEqual(["segment-1", "segment-2"])
    expect(value.failures).toEqual([])
  })

  test("exhausted final retries discard the queued successor", async () => {
    const first = deferred<void>()
    const attempts: string[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId) { attempts.push(turnId); await first.promise; throw new TranscriptionError("provider") },
    } })
    await utterance(value)
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.final("segment-2", "Must not pass the failed predecessor.")
    first.resolve()
    await until(() => value.failures.length === 1)
    await value.worker.stop(true)
    expect(attempts).toEqual(["segment-1", "segment-1"])
    expect(value.failures.map((failure) => failure.code)).toEqual(["provider"])
  })

  test("run authority is rechecked before allowing a queued successor", async () => {
    const first = deferred<void>()
    const attempts: string[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId) { attempts.push(turnId); await first.promise },
    } })
    await utterance(value)
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.final("segment-2", "Must not persist after authority loss.")
    value.revokeRun()
    first.resolve()
    await until(() => value.failures.length === 1)
    expect(attempts).toEqual(["segment-1"])
    expect(value.failures[0]?.code).toBe("expired")
    await value.worker.stop(false)
  })

  test("graceful Stop times out a held post and discards its queued successor", async () => {
    const first = deferred<void>()
    const attempts: string[] = []
    let id = 0
    const value = fixture({ api: {
      async admit() { return `segment-${++id}` },
      async final(turnId) { attempts.push(turnId); await first.promise },
    } })
    await utterance(value)
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.final("segment-2", "Must not persist after the drain deadline.")
    const began = performance.now()
    await value.worker.stop(true)
    const elapsed = performance.now() - began
    expect(elapsed).toBeGreaterThanOrEqual(4_900)
    expect(elapsed).toBeLessThan(6_000)
    expect(value.events).toContain("close")
    first.resolve()
    await tick(); await tick()
    expect(attempts).toEqual(["segment-1"])
    expect(value.failures).toEqual([])
  }, 7_000)

  test("queued samples are discarded if membership changes before inference", async () => {
    const value = fixture()
    value.worker.push(frame(true))
    value.revokeMicrophone()
    await until(() => value.failures.length === 1)
    expect(value.events).not.toContain("admit")
    expect(value.audio).toHaveLength(0)
    expect(value.failures[0]?.code).toBe("stopped")
  })

  test("late admission after Stop retires empty without opening the provider", async () => {
    const admitted = deferred<string>()
    const value = fixture({ api: { admit() { return admitted.promise }, async final(turnId, text) {
      value.finals.push({ turnId, text })
    } } })
    value.worker.push(frame(true))
    await tick(); await tick()
    const stopped = value.worker.stop(true)
    admitted.resolve("late-segment")
    await stopped
    expect(value.finals).toEqual([{ turnId: "late-segment", text: "" }])
    expect(value.events).not.toContain("connect")
    expect(value.audio).toHaveLength(0)
  })

  test("late admission retirement waits behind an earlier final during graceful Stop", async () => {
    const first = deferred<void>()
    const admitted = deferred<string>()
    const attempts: string[] = []
    const saved: FinalTurn[] = []
    let admissions = 0
    const value = fixture({ api: {
      async admit() { return ++admissions === 1 ? "segment-1" : admitted.promise },
      async final(turnId, text) {
        attempts.push(turnId)
        if (turnId === "segment-1") await first.promise
        saved.push({ turnId, text })
      },
    } })
    await utterance(value)
    value.final("segment-1", "First phrase.")
    value.worker.push(frame(true))
    await until(() => admissions === 2)
    const stopping = value.worker.stop(true)
    admitted.resolve("segment-2")
    await tick()
    expect(attempts).toEqual(["segment-1"])
    first.resolve()
    await stopping
    expect(saved).toEqual([
      { turnId: "segment-1", text: "First phrase." },
      { turnId: "segment-2", text: "" },
    ])
    expect(value.commits).toEqual(["segment-1"])
    expect(value.failures).toEqual([])
  })

  test("late provider connect is closed after destructive stop and never sends PCM", async () => {
    const connected = deferred<SpeechConnection>()
    let started = false
    const value = fixture({ connect() { started = true; return connected.promise } })
    value.worker.push(frame(true))
    await until(() => started)
    await value.worker.stop(false)
    connected.resolve(value.connection)
    await tick(); await tick()
    expect(value.audio).toHaveLength(0)
    expect(value.events).toContain("close")
    expect(value.finals).toHaveLength(0)
  })

  test("ordinary voice leave accepts only the already admitted final", async () => {
    const value = fixture()
    await utterance(value)
    const capturedBeforeLeave = value.audio.length
    value.revokeMicrophone()
    const stopping = value.worker.stop(true)
    expect(() => value.worker.push(frame(true))).toThrow("stopped")
    value.final("segment-1", "Finished before leaving.")
    await stopping
    expect(value.audio).toHaveLength(capturedBeforeLeave)
    expect(value.finals).toEqual([{ turnId: "segment-1", text: "Finished before leaving." }])
    expect(value.failures).toHaveLength(0)
  })

  test("loss of run authority discards provider finals before API persistence", async () => {
    const value = fixture()
    await utterance(value)
    value.revokeRun()
    expect(() => value.final("segment-1", "Must not persist.")).toThrow("expired")
    expect(value.finals).toHaveLength(0)
    await value.worker.stop(false)
  })

  test("a slow provider buffers speech without blocking capture, up to the backlog bound", async () => {
    const connected = deferred<SpeechConnection>()
    let started = false
    const value = fixture({ maxBacklogMs: 1_000, connect() { started = true; return connected.promise } })
    value.worker.push(frame(true))
    await until(() => started)
    for (let index = 0; index < 100; index++) value.worker.push(frame(true))
    await until(() => value.failures.length > 0)
    expect(value.failures[0]?.code).toBe("overflow")
    connected.resolve(value.connection)
    await tick(); await tick()
    expect(value.audio).toHaveLength(0)
  })

  test("two unresolved commits bound the provider while later turns wait admitted", async () => {
    const value = fixture()
    await utterance(value)
    await utterance(value)
    value.worker.push(frame(true))
    for (let index = 0; index < 28; index++) value.worker.push(frame(false))
    await until(() => value.events.filter((event) => event === "admit").length === 3)
    await tick(); await tick()
    expect(value.commits).toEqual(["segment-1", "segment-2"])
    value.final("segment-1", "First.")
    await until(() => value.commits.length === 3)
    expect(value.commits).toEqual(["segment-1", "segment-2", "segment-3"])
    expect(value.failures).toEqual([])
    await value.worker.stop(false)
  })
})
