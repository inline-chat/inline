import { trustedScriptUrl } from "../../sw/trusted-script-url"
import labWorkerUrl from "./worker.ts?worker&url"

type Reply =
  | { id: number; ok: true; value: unknown }
  | { id: number; ok: false; reason: string; message: string; cause?: string }

class LabWorker {
  private readonly worker = new Worker(trustedScriptUrl(labWorkerUrl) as string | URL, { type: "module" })
  private nextId = 1
  private readonly waiting = new Map<number, (reply: Reply) => void>()

  constructor() {
    this.worker.addEventListener("message", (event: MessageEvent<Reply>) => {
      this.waiting.get(event.data.id)?.(event.data)
      this.waiting.delete(event.data.id)
    })
  }

  call(command: Record<string, unknown>): Promise<Reply> {
    const id = this.nextId++
    return new Promise((resolve) => {
      this.waiting.set(id, resolve)
      this.worker.postMessage({ id, ...command })
    })
  }

  terminate() {
    this.worker.terminate()
  }
}

type Step = { name: string; pass: boolean; detail: string }

const steps: Step[] = []
const check = (name: string, pass: boolean, detail: unknown) => {
  steps.push({ name, pass, detail: typeof detail === "string" ? detail : JSON.stringify(detail) })
}

const run = async () => {
  const account = "1001"
  const other = "1002"

  // Start from nothing.
  const cleaner = new LabWorker()
  await cleaner.call({ cmd: "erase", account })
  await cleaner.call({ cmd: "erase", account: other })
  cleaner.terminate()

  const a = new LabWorker()
  const openedA = await a.call({ cmd: "open", account })
  check("A opens the account", openedA.ok, openedA)
  await a.call({ cmd: "set", value: "written-by-A" })

  const b = new LabWorker()
  const started = performance.now()
  const openedB = await b.call({ cmd: "open", account })
  const waited = Math.round(performance.now() - started)
  check(
    "B is refused as busy while A holds the storage",
    !openedB.ok && openedB.reason === "opfs-busy",
    { ...openedB, waitedMs: waited },
  )
  b.terminate()

  const stillThere = await a.call({ cmd: "get" })
  check(
    "A still reads its data after B's failed open",
    stillThere.ok && stillThere.value === "written-by-A",
    stillThere,
  )

  const e = new LabWorker()
  const openedOther = await e.call({ cmd: "open", account: other })
  check("Another account opens while the first is held", openedOther.ok, openedOther)
  await e.call({ cmd: "set", value: "other-account" })

  // Takeover: D starts while A holds, A goes away shortly after.
  const d = new LabWorker()
  const pendingD = d.call({ cmd: "open", account })
  setTimeout(() => a.terminate(), 300)
  const openedD = await pendingD
  check("D takes over once A is gone, inside the retry window", openedD.ok, openedD)
  const survived = await d.call({ cmd: "get" })
  check(
    "The data survived a failed open and a takeover",
    survived.ok && survived.value === "written-by-A",
    survived,
  )

  await e.call({ cmd: "close" })
  const erased = await e.call({ cmd: "erase", account: other })
  check("Erasing the other account succeeds", erased.ok, erased)
  await e.call({ cmd: "open", account: other })
  const afterErase = await e.call({ cmd: "get" })
  check("The erased account is empty", afterErase.ok && afterErase.value === null, afterErase)
  const untouched = await d.call({ cmd: "get" })
  check(
    "Erasing one account leaves the other's data",
    untouched.ok && untouched.value === "written-by-A",
    untouched,
  )

  d.terminate()
  e.terminate()
}

const out = document.getElementById("out")
run()
  .catch((error: unknown) => {
    check("lab ran to completion", false, error instanceof Error ? error.message : String(error))
  })
  .finally(() => {
    const passed = steps.every((step) => step.pass)
    const text = [
      passed ? "ALL PASSED" : "FAILED",
      ...steps.map((step) => `${step.pass ? "pass" : "FAIL"}  ${step.name}\n      ${step.detail}`),
    ].join("\n")
    if (out) out.textContent = text
    ;(globalThis as { __storageLab?: unknown }).__storageLab = { passed, steps }
  })
