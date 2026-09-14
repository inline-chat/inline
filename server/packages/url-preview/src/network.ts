import { lookup as nodeLookup } from "node:dns/promises"
import { isIP } from "node:net"

import {
  ALLOWED_IMAGE_TYPES,
  DEFAULT_MAX_BINARY_BYTES,
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_USER_AGENT,
} from "./constants.js"
import { UrlPreviewError } from "./errors.js"
import { isBlockedIp, stripIpv6Brackets } from "./filters.js"
import { normalizePreviewUrl } from "./normalize.js"
import type { FetchBinaryOptions, FetchBinaryResult, FetchImpl, LookupAddress, LookupFn } from "./types.js"

export type FetchWithRedirectsOptions = {
  fetchImpl: FetchImpl
  lookup: LookupFn
  timeoutMs: number
  maxRedirects: number
  userAgent: string
  accept: string
  headers?: Record<string, string>
}

export type FetchByteRangeOptions = {
  fetchImpl?: FetchImpl
  lookup?: LookupFn
  timeoutMs?: number
  maxRedirects?: number
  maxBytes?: number
  userAgent?: string
  accept?: string
}

export type FetchByteRangeResult = {
  bytes: Uint8Array
  contentType: string
  finalUrl: string
  contentRange?: string
}

export async function fetchBinary(url: string, options: FetchBinaryOptions = {}): Promise<FetchBinaryResult | null> {
  const normalized = normalizePreviewUrl(url)
  if (!normalized) {
    return null
  }

  const response = await fetchWithRedirects(normalized, {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.1",
  })

  if (!response.response.ok) {
    return null
  }

  const contentType = baseContentType(response.response.headers.get("content-type"))
  const allowed = options.allowedContentTypes ?? ALLOWED_IMAGE_TYPES
  if (!contentType || !allowed.some((type) => contentType === type || contentType.startsWith(`${type};`))) {
    return null
  }

  const bytes = await readResponseBytes(response.response, options.maxBytes ?? DEFAULT_MAX_BINARY_BYTES)
  return { bytes, contentType, finalUrl: response.finalUrl }
}

export async function fetchByteRange(
  url: string,
  range: string,
  options: FetchByteRangeOptions = {},
): Promise<FetchByteRangeResult | null> {
  const normalized = normalizePreviewUrl(url)
  if (!normalized) {
    return null
  }

  const response = await fetchWithRedirects(normalized, {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: options.accept ?? "video/*,application/octet-stream;q=0.8,*/*;q=0.1",
    headers: {
      Range: range,
    },
  })

  if (!response.response.ok && response.response.status !== 206) {
    return null
  }

  const bytes = await readResponseBytes(response.response, options.maxBytes ?? DEFAULT_MAX_BINARY_BYTES)
  return {
    bytes,
    contentType: baseContentType(response.response.headers.get("content-type")),
    finalUrl: response.finalUrl,
    contentRange: response.response.headers.get("content-range") ?? undefined,
  }
}

export async function fetchWithRedirects(
  initialUrl: string,
  options: FetchWithRedirectsOptions,
): Promise<{ response: Response; finalUrl: string }> {
  let currentUrl = initialUrl

  for (let redirectCount = 0; redirectCount <= options.maxRedirects; redirectCount += 1) {
    currentUrl = await normalizeSafeFetchUrl(currentUrl, options.lookup)

    const response = await fetchOnce(currentUrl, options)
    if (!isRedirect(response.status)) {
      return { response, finalUrl: currentUrl }
    }

    const location = response.headers.get("location")
    if (!location) {
      return { response, finalUrl: currentUrl }
    }

    currentUrl = new URL(location, currentUrl).toString()
  }

  throw new UrlPreviewError("Too many redirects", "too_many_redirects")
}

export async function readResponseText(response: Response, maxBytes: number): Promise<string> {
  const bytes = await readResponseBytes(response, maxBytes)
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes)
}

export async function readResponseTextPrefix(response: Response, maxBytes: number): Promise<string> {
  const bytes = await readResponsePrefixBytes(response, maxBytes)
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes)
}

async function fetchOnce(url: string, options: FetchWithRedirectsOptions): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs)

  try {
    return await options.fetchImpl(url, {
      redirect: "manual",
      signal: controller.signal,
      headers: {
        Accept: options.accept,
        "User-Agent": options.userAgent,
        ...options.headers,
      },
    })
  } finally {
    clearTimeout(timeout)
  }
}

async function normalizeSafeFetchUrl(urlString: string, lookup: LookupFn): Promise<string> {
  const normalized = normalizePreviewUrl(urlString)
  if (!normalized) {
    throw new UrlPreviewError("URL is not previewable", "invalid_url")
  }

  const url = new URL(normalized)
  const hostname = stripIpv6Brackets(url.hostname)

  if (isIP(hostname) !== 0) {
    if (isBlockedIp(hostname)) {
      throw new UrlPreviewError("IP is not previewable", "blocked_ip")
    }
    return normalized
  }

  let addresses: LookupAddress[]
  try {
    addresses = await lookup(hostname)
  } catch (error) {
    throw new UrlPreviewError(`DNS lookup failed: ${error instanceof Error ? error.message : "unknown"}`, "dns_failed")
  }

  if (addresses.length === 0 || addresses.some((address) => isBlockedIp(address.address))) {
    throw new UrlPreviewError("Resolved address is not previewable", "blocked_ip")
  }

  return normalized
}

export async function defaultLookup(hostname: string): Promise<LookupAddress[]> {
  return nodeLookup(hostname, { all: true, verbatim: true })
}

async function readResponseBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  const contentLength = Number(response.headers.get("content-length") ?? 0)
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new UrlPreviewError("Response too large", "response_too_large")
  }

  if (!response.body) {
    return new Uint8Array(await response.arrayBuffer())
  }

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0

  while (true) {
    const { done, value } = await reader.read()
    if (done) {
      break
    }
    if (!value) {
      continue
    }
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined)
      throw new UrlPreviewError("Response too large", "response_too_large")
    }
    chunks.push(value)
  }

  const output = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}

async function readResponsePrefixBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  if (!response.body) {
    return new Uint8Array(await response.arrayBuffer()).slice(0, maxBytes)
  }

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0

  while (total < maxBytes) {
    const { done, value } = await reader.read()
    if (done) {
      break
    }
    if (!value) {
      continue
    }

    const available = maxBytes - total
    const chunk = value.byteLength > available ? value.slice(0, available) : value
    chunks.push(chunk)
    total += chunk.byteLength

    if (chunk.byteLength < value.byteLength) {
      await reader.cancel().catch(() => undefined)
      break
    }
  }

  const output = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308
}

export function baseContentType(contentType: string | null): string {
  return contentType?.split(";")[0]?.trim().toLowerCase() ?? ""
}
