export type ShutdownSignal = "manual" | "timeout" | "error" | "SIGINT" | "SIGTERM"

export type ShutdownState = {
  shuttingDown: boolean
  signal: ShutdownSignal | null
  startedAtMs: number | null
}

const shutdownState: ShutdownState = {
  shuttingDown: false,
  signal: null,
  startedAtMs: null,
}

export const markServerShuttingDown = (signal: ShutdownSignal = "manual"): void => {
  if (shutdownState.shuttingDown) {
    return
  }

  shutdownState.shuttingDown = true
  shutdownState.signal = signal
  shutdownState.startedAtMs = Date.now()
}

export const isServerShuttingDown = (): boolean => shutdownState.shuttingDown

export const getServerShutdownState = (): ShutdownState => ({
  ...shutdownState,
})

export const resetServerShutdownStateForTests = (): void => {
  shutdownState.shuttingDown = false
  shutdownState.signal = null
  shutdownState.startedAtMs = null
}
