import { Log } from "@in/server/utils/log"

const log = new Log("measure")

export const measureTime = (method: string) => {
  let start: number | undefined
  let end: number | undefined
  let duration: number | undefined

  return {
    start: () => {
      start = performance.now()
    },
    end: () => {
      if (!start) {
        console.error(`[measureTime] start was not called for ${method}`)
        return
      }
      end = performance.now()
      duration = end - start

      log.debug(`${method} took ${duration}ms`)
    },
  }
}
