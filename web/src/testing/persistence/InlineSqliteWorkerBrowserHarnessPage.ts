type HarnessPhase = "warmup" | "seed" | "verify" | "selection"

type WorkerResult = {
  phase: "seed" | "verify"
  openMs: number
  seedMs?: number
  longestBatchMs?: number
  latestMs: number
  aroundMs: number
  latestCount: number
  latestFirstId?: string
  latestLastId?: string
  aroundCount: number
  aroundFirstId?: string
  aroundLastId?: string
  exactUserId?: string
  transactionId?: string
  lastSyncDate?: number
  databaseBytes?: number
}

type SelectionResult = {
  phase: "selection"
  primaryPhase: string
  legacySeedMs: number
  legacyLongestBatchMs: number
  primaryOpenMs: number
  importedUserName?: string
  importedDraftText?: string
  importedOutboxId?: string
  importedOutboxRandomId?: string
  markedUserName?: string
  promotedFallbackRefused: boolean
  promotedFallbackPhase: string
  currentRuntimeRefused: boolean
  fallbackPhase: string
  restartPhase: string
  fallbackUserId?: string
  fallbackOutboxId?: string
  fallbackOutboxRandomId?: string
  refusedReason: string
  unsafeFallbackCreated: boolean
}

const runWorker = <Result>(phase: HarnessPhase) =>
  new Promise<Result>((resolve, reject) => {
    const worker = new Worker(
      new URL(
        "./InlineSqliteWorkerBrowserHarness.worker.ts",
        import.meta.url,
      ),
      { type: "module" },
    )
    const timeout = setTimeout(() => {
      worker.terminate()
      reject(new Error(`SQLite ${phase} worker timed out`))
    }, 120_000)
    worker.addEventListener("message", (event) => {
      const message = event.data as {
        type: "result" | "error"
        result?: Result
        error?: { name: string; message: string; stack?: string }
      }
      clearTimeout(timeout)
      worker.terminate()
      if (message.type === "result" && message.result) {
        resolve(message.result)
      } else {
        const error = new Error(
          message.error?.message ?? "SQLite worker failed",
        )
        error.name = message.error?.name ?? "Error"
        error.stack = message.error?.stack ?? error.stack
        reject(error)
      }
    })
    worker.addEventListener("error", (event) => {
      clearTimeout(timeout)
      worker.terminate()
      reject(event.error ?? new Error(event.message))
    })
    worker.postMessage({ phase })
  })

const run = async () => {
  // Keep initial Vite/module evaluation and the first Worker module graph
  // outside the responsiveness sample. Product starts its core Worker before
  // cached chat interaction; this also keeps Vite transform work out of the
  // persistence measurement.
  await runWorker<{ phase: "warmup" }>("warmup")
  await new Promise<void>((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
  )
  const longTasks: Array<{ startTime: number; duration: number }> = []
  const frameGaps: Array<{ timestamp: number; duration: number }> = []
  const phaseRanges: Array<{
    phase: HarnessPhase
    startTime: number
    endTime: number
  }> = []
  let measuringFrames = true
  let previousFrame = performance.now()
  const measureFrame = (timestamp: number) => {
    frameGaps.push({
      timestamp,
      duration: timestamp - previousFrame,
    })
    previousFrame = timestamp
    if (measuringFrames) requestAnimationFrame(measureFrame)
  }
  requestAnimationFrame(measureFrame)
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      longTasks.push({
        startTime: entry.startTime,
        duration: entry.duration,
      })
    }
  })
  try {
    observer.observe({ type: "longtask", buffered: true })
  } catch {
    // Long Task API is not implemented in every target browser.
  }

  const runPhase = async <Result>(phase: HarnessPhase) => {
    const startTime = performance.now()
    const result = await runWorker<Result>(phase)
    phaseRanges.push({
      phase,
      startTime,
      endTime: performance.now(),
    })
    return result
  }
  const seed = await runPhase<WorkerResult>("seed")
  const verify = await runPhase<WorkerResult>("verify")
  const selection = await runPhase<SelectionResult>("selection")
  measuringFrames = false
  observer.disconnect()
  const phaseFor = (timestamp: number) =>
    phaseRanges.find(
      (range) =>
        timestamp >= range.startTime && timestamp <= range.endTime,
    )?.phase ?? "outside"
  const maxFrameGapByPhase = Object.fromEntries(
    ["seed", "verify", "selection"].map((phase) => [
      phase,
      Math.max(
        0,
        ...frameGaps
          .filter((entry) => phaseFor(entry.timestamp) === phase)
          .map((entry) => entry.duration),
      ),
    ]),
  )
  return {
    seed,
    verify,
    selection,
    mainThreadLongTasks: longTasks.map((entry) => ({
      ...entry,
      phase: phaseFor(entry.startTime),
    })),
    mainThreadFrameGaps: frameGaps
      .filter((entry) => entry.duration >= 30)
      .map((entry) => ({
        ...entry,
        phase: phaseFor(entry.timestamp),
      })),
    mainThreadMaxFrameGapByPhase: maxFrameGapByPhase,
    mainThreadMaxFrameGapMs: Math.max(
      0,
      ...frameGaps.map((entry) => entry.duration),
    ),
    mainThreadFrameCount: frameGaps.length,
  }
}

declare global {
  interface Window {
    inlineSqliteWorkerHarnessReady?: Promise<Awaited<ReturnType<typeof run>>>
  }
}

window.inlineSqliteWorkerHarnessReady = run()
