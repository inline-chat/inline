// Preserve Bun's previous listener cap for every route except /v1/uploadFile.
export const DEFAULT_HTTP_REQUEST_MAX_BYTES = 128 * 1024 * 1024

export const isLegacyFileUploadRequest = (request: Request): boolean =>
  request.method === "POST" && new URL(request.url).pathname === "/v1/uploadFile"

/** Enforce the old cap before raw compatibility parsers can buffer the body. */
export const limitHttpRequestBody = (
  request: Request,
  maxBytes = DEFAULT_HTTP_REQUEST_MAX_BYTES,
): Response | { request: Request; limitReached: Promise<Response> } => {
  const tooLarge = () => new Response("Request body too large", { status: 413 })
  const contentLength = request.headers.get("content-length")
  if (contentLength !== null && Number(contentLength) > maxBytes) return tooLarge()
  let reached!: (response: Response) => void
  const limitReached = new Promise<Response>((resolve) => { reached = resolve })
  if (!request.body) return { request, limitReached }
  const controller = new AbortController()
  let received = 0
  const body = request.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, output) {
      received += chunk.byteLength
      if (received > maxBytes) {
        const reason = new RangeError("Request body too large")
        reached(tooLarge())
        controller.abort(reason)
        throw reason
      }
      output.enqueue(chunk)
    },
  }))
  return {
    request: new Request(request, {
      method: request.method,
      body,
      signal: AbortSignal.any([request.signal, controller.signal]),
    }),
    limitReached,
  }
}
