const ERROR_WINDOW_MS = 1000 * 60 * 15
const FIVE_MINUTES_MS = 1000 * 60 * 5

const errorTimestamps: number[] = []
let totalErrors = 0

const cleanupErrors = (now: number) => {
  const cutoff = now - ERROR_WINDOW_MS
  while (errorTimestamps.length > 0) {
    const first = errorTimestamps[0]
    if (first === undefined || first >= cutoff) {
      break
    }
    errorTimestamps.shift()
  }
}

export const recordApiError = () => {
  const now = Date.now()
  totalErrors += 1
  errorTimestamps.push(now)
  cleanupErrors(now)
}

export const getErrorStats = () => {
  const now = Date.now()
  cleanupErrors(now)

  const last5m = errorTimestamps.filter((timestamp) => timestamp >= now - FIVE_MINUTES_MS).length
  const last15m = errorTimestamps.length

  return {
    last5m,
    last15m,
    total: totalErrors,
  }
}
