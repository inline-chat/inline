import { DEFAULT_TIMEOUT_MS, DEFAULT_USER_AGENT } from "../constants.js"
import { UrlPreviewError } from "../errors.js"
import { readResponseText } from "../network.js"
import type { AuthPreviewOptions } from "./types.js"

export class ProviderFetchError extends UrlPreviewError {
  constructor(
    message: string,
    code: string,
    public readonly status?: number,
  ) {
    super(message, code)
    this.name = "ProviderFetchError"
  }
}

export type ProviderJsonFetchOptions = AuthPreviewOptions & {
  allowedHosts: readonly string[]
  headers?: Record<string, string>
  maxRedirects?: number
}

const defaultMaxResponseBytes = 512 * 1024

export async function fetchProviderJson(input: string, options: ProviderJsonFetchOptions): Promise<unknown> {
  const fetchImpl = options.fetchImpl ?? fetch
  const maxRedirects = options.maxRedirects ?? 2
  let url = normalizeAllowedProviderUrl(input, options.allowedHosts)

  for (let redirects = 0; redirects <= maxRedirects; redirects += 1) {
    const response = await fetchProviderOnce(url, options)
    if (!isRedirect(response.status)) {
      if (!response.ok) {
        await response.body?.cancel().catch(() => undefined)
        throw new ProviderFetchError("Provider returned an error", "provider_status", response.status)
      }

      const text = await readResponseText(response, options.maxResponseBytes ?? defaultMaxResponseBytes)
      if (!text.trim()) {
        return null
      }

      try {
        return JSON.parse(text) as unknown
      } catch {
        throw new ProviderFetchError("Provider returned invalid JSON", "invalid_json", response.status)
      }
    }

    const location = response.headers.get("location")
    await response.body?.cancel().catch(() => undefined)
    if (!location) {
      throw new ProviderFetchError("Provider redirect is missing location", "invalid_redirect", response.status)
    }

    url = normalizeAllowedProviderUrl(new URL(location, url).toString(), options.allowedHosts)
  }

  throw new ProviderFetchError("Provider returned too many redirects", "too_many_redirects")

  async function fetchProviderOnce(targetUrl: string, fetchOptions: ProviderJsonFetchOptions): Promise<Response> {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), fetchOptions.timeoutMs ?? DEFAULT_TIMEOUT_MS)

    try {
      return await fetchImpl(targetUrl, {
        redirect: "manual",
        signal: controller.signal,
        headers: {
          Accept: "application/json",
          "User-Agent": fetchOptions.userAgent ?? DEFAULT_USER_AGENT,
          ...fetchOptions.headers,
        },
      })
    } finally {
      clearTimeout(timeout)
    }
  }
}

function normalizeAllowedProviderUrl(input: string, allowedHosts: readonly string[]): string {
  const url = new URL(input)
  if (url.protocol !== "https:") {
    throw new ProviderFetchError("Provider URL must use HTTPS", "invalid_url")
  }
  if (url.username || url.password) {
    throw new ProviderFetchError("Provider URL must not include credentials", "invalid_url")
  }

  const host = url.hostname.toLowerCase()
  if (!allowedHosts.some((allowed) => host === allowed.toLowerCase())) {
    throw new ProviderFetchError("Provider URL host is not allowed", "blocked_host")
  }

  return url.toString()
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308
}
