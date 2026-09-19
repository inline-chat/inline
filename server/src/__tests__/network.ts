/** Provider requests must use an injected fake. Real fetch is for local servers. */
export function localOnlyFetch(realFetch: typeof fetch, onDenied: (host: string) => void): typeof fetch {
  const guarded = ((input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) {
      // Do not print request paths, query strings, credentials, or bodies.
      onDenied(url.hostname)
      return Promise.reject(new Error(`External fetch blocked in tests (${url.hostname}); inject a provider fake.`))
    }
    // A local endpoint must not redirect the real client to an external service.
    return realFetch(input, { ...init, redirect: "error" })
  }) as typeof fetch
  return Object.assign(guarded, realFetch)
}
