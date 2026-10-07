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
  return { worker, connection, events, audio, commits, finals, failures,
    final(turnId: string, text: string) { options?.onFinal({ turnId, text }) },
    revokeMicrophone() { microphone = false }, revokeRun() { authority = false } }
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
    await until(() => value.events.includes("close"))
    await utterance(value)
    await until(() => value.commits.length === 2)
    expect(value.events.filter((event) => event === "connect")).toHaveLength(2)
    expect(value.commits).toEqual(["segment-1", "segment-2"])
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

  test("a slow provider cannot create an unbounded native PCM queue", async () => {
    const connected = deferred<SpeechConnection>()
    let started = false
    const value = fixture({ connect() { started = true; return connected.promise } })
    value.worker.push(frame(true))
    await until(() => started)
    for (let index = 0; index < 100; index++) value.worker.push(frame(true))
    expect(() => value.worker.push(frame(true))).toThrow("overflow")
    connected.resolve(value.connection)
    await tick(); await tick()
    expect(value.failures[0]?.code).toBe("overflow")
    expect(value.audio).toHaveLength(0)
  })

  test("two unresolved commits bound provider and server admission backlog", async () => {
    const value = fixture()
    await utterance(value)
    const before = value.commits.length
    value.worker.push(frame(true))
    for (let index = 0; index < 28; index++) value.worker.push(frame(false))
    await until(() => value.commits.length > before)
    value.worker.push(frame(true))
    await until(() => value.failures.length > 0)
    expect(value.commits).toEqual(["segment-1", "segment-2"])
    expect(value.events.filter((event) => event === "admit")).toHaveLength(2)
    expect(value.failures[0]?.code).toBe("overflow")
  })
})
