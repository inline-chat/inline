type ActiveRun = {
  readonly runId: string
  readonly runKey: string
  readonly controller: AbortController
  timer?: ReturnType<typeof setTimeout>
}

const activeByRunKey = new Map<string, ActiveRun>()
const activeByRunId = new Map<string, ActiveRun>()

export function registerActiveRun(input: {
  readonly runId: string
  readonly runKey: string
  readonly controller: AbortController
  readonly timer?: ReturnType<typeof setTimeout>
}): void {
  const run = { ...input }
  activeByRunKey.set(input.runKey, run)
  activeByRunId.set(input.runId, run)
}

export function setActiveRunTimer(runId: string, timer: ReturnType<typeof setTimeout>): void {
  const run = activeByRunId.get(runId)
  if (run) {
    run.timer = timer
  }
}

export function cancelActiveRunKey(runKey: string): string | undefined {
  const run = activeByRunKey.get(runKey)
  if (!run) {
    return undefined
  }

  if (run.timer) {
    clearTimeout(run.timer)
  }
  run.controller.abort()
  activeByRunKey.delete(run.runKey)
  activeByRunId.delete(run.runId)
  return run.runId
}

export function cancelActiveRunId(runId: string): void {
  const run = activeByRunId.get(runId)
  if (!run) {
    return
  }
  if (run.timer) {
    clearTimeout(run.timer)
  }
  run.controller.abort()
  activeByRunKey.delete(run.runKey)
  activeByRunId.delete(run.runId)
}

export function finishActiveRun(runId: string): void {
  const run = activeByRunId.get(runId)
  if (!run) {
    return
  }
  activeByRunKey.delete(run.runKey)
  activeByRunId.delete(runId)
}
