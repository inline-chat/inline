/**
 * The network as the tests see it: files served by URL, an offline switch,
 * per-URL failures, and a log of every request that reached it.
 */

export const TEST_ORIGIN = "https://app.test"

export interface NetworkRequestRecord {
  /** Path for the app origin, full URL otherwise. */
  readonly url: string
  readonly method: string
  readonly mode: string
}

interface ServedFile {
  readonly body: Uint8Array
  readonly headers: Record<string, string>
}

const encoder = new TextEncoder()

const display = (href: string): string => {
  const url = new URL(href)
  return url.origin === TEST_ORIGIN ? `${url.pathname}${url.search}` : href
}

export class FakeNetwork {
  online = true
  readonly log: NetworkRequestRecord[] = []
  private readonly files = new Map<string, ServedFile>()
  private readonly failing = new Map<string, number>()

  /** Serves `body` at `url` (a path on the app origin, or a full URL). */
  serve(url: string, body: string | Uint8Array, headers: Record<string, string> = {}): void {
    this.files.set(new URL(url, TEST_ORIGIN).href, {
      body: typeof body === "string" ? encoder.encode(body) : body,
      headers,
    })
  }

  remove(url: string): void {
    this.files.delete(new URL(url, TEST_ORIGIN).href)
  }

  /** Requests for `url` answer with this HTTP status until `heal`. */
  fail(url: string, status = 500): void {
    this.failing.set(new URL(url, TEST_ORIGIN).href, status)
  }

  heal(url: string): void {
    this.failing.delete(new URL(url, TEST_ORIGIN).href)
  }

  /** Requests logged since the last call, as display URLs. */
  take(): string[] {
    return this.log.splice(0).map((record) => record.url)
  }

  readonly fetch = async (input: Request | string, init?: RequestInit): Promise<Response> => {
    const request = typeof input === "string" ? new Request(new URL(input, TEST_ORIGIN), init) : input
    const url = new URL(request.url)
    url.hash = ""
    this.log.push({ url: display(url.href), method: request.method, mode: request.mode })
    if (!this.online) throw new TypeError("Failed to fetch")
    const status = this.failing.get(url.href)
    if (status !== undefined) return new Response("failure", { status })
    // Files are keyed without the query: a static host ignores it.
    const file = this.files.get(`${url.origin}${url.pathname}`)
    if (!file) return new Response("not found", { status: 404 })
    return new Response(file.body.slice(), { status: 200, headers: file.headers })
  }
}
