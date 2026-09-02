// Read exactly a bounded range, including cancellation of the underlying
// stream. Never materialize an oversized object before checking its length.
export async function readFileBytes(
  stream: ReadableStream<Uint8Array>,
  length: number,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  const reader = stream.getReader()
  const cancel = () => { void reader.cancel(signal?.reason).catch(() => {}) }
  signal?.addEventListener("abort", cancel, { once: true })
  const bytes = new Uint8Array(length)
  let received = 0
  try {
    signal?.throwIfAborted()
    for (;;) {
      const { done, value } = await reader.read()
      signal?.throwIfAborted()
      if (done) break
      if (value.length > length - received) throw new FileByteLengthError()
      bytes.set(value, received)
      received += value.length
    }
    if (received !== length) throw new FileByteLengthError()
    return bytes
  } finally {
    signal?.removeEventListener("abort", cancel)
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}

export class FileByteLengthError extends Error {
  constructor() { super("File bytes do not match the expected range length") }
}
