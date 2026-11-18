/**
 * One real event-loop turn, captured before any fake timers are installed.
 * Every queued promise callback runs before it resolves. Kept free of
 * Vitest so non-test code (a browser harness) can use the transport.
 */
const realSetImmediate: (callback: () => void) => unknown =
  typeof globalThis.setImmediate === "function"
    ? globalThis.setImmediate.bind(globalThis)
    : typeof MessageChannel === "function"
      ? (callback) => {
          const channel = new MessageChannel()
          channel.port1.onmessage = () => {
            channel.port1.close()
            callback()
          }
          channel.port2.postMessage(undefined)
        }
      : (callback) => Promise.resolve().then(callback)

export const realTurn = () =>
  new Promise<void>((resolve) => {
    realSetImmediate(resolve)
  })
