import {
  ExternalProfilePhotoStatus,
  ExternalProfileProvider,
  type GetExternalProfilePhotoResult,
} from "@inline-chat/protocol/core"
import {
  fetchBinary,
  fetchUrlPreview,
  type FetchImpl,
  type LookupFn,
} from "@inline-chat/url-preview"

const MAX_PROFILE_PHOTO_BYTES = 1 * 1024 * 1024
const MAX_PROFILE_HTML_BYTES = 256 * 1024
const LOOKUP_TIMEOUT_MS = 10_000
const SUCCESS_CACHE_TTL_MS = 24 * 60 * 60 * 1_000
const NOT_FOUND_CACHE_TTL_MS = 5 * 60 * 1_000
const DEFAULT_CACHE_CAPACITY = 64

type ResolverOptions = {
  fetchImpl?: FetchImpl
  lookup?: LookupFn
  now?: () => number
  cacheCapacity?: number
}

type CacheEntry = {
  expiresAt: number
  result: GetExternalProfilePhotoResult
}

export class ExternalProfilePhotoResolver {
  private readonly cache = new Map<string, CacheEntry>()
  private readonly fetchImpl: FetchImpl | undefined
  private readonly lookup: LookupFn | undefined
  private readonly now: () => number
  private readonly cacheCapacity: number

  constructor(options: ResolverOptions = {}) {
    this.fetchImpl = options.fetchImpl
    this.lookup = options.lookup
    this.now = options.now ?? Date.now
    this.cacheCapacity = Math.max(1, options.cacheCapacity ?? DEFAULT_CACHE_CAPACITY)
  }

  async resolve(provider: ExternalProfileProvider, rawUsername: string): Promise<GetExternalProfilePhotoResult> {
    const username = normalizeExternalUsername(provider, rawUsername)
    if (!username) {
      return unavailable()
    }

    const cacheKey = `${provider}:${username.toLowerCase()}`
    const cached = this.cached(cacheKey)
    if (cached) {
      return cached
    }

    const result = await this.resolveUncached(provider, username)
    if (result.status === ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_FOUND) {
      this.store(cacheKey, result, SUCCESS_CACHE_TTL_MS)
    } else if (result.status === ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_NOT_FOUND) {
      this.store(cacheKey, result, NOT_FOUND_CACHE_TTL_MS)
    }
    return result
  }

  private async resolveUncached(
    provider: ExternalProfileProvider,
    username: string,
  ): Promise<GetExternalProfilePhotoResult> {
    switch (provider) {
      case ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X:
        return this.resolveX(username)
      case ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_UNSPECIFIED:
      default:
        return unavailable()
    }
  }

  private async resolveX(username: string): Promise<GetExternalProfilePhotoResult> {
    const profileUrl = `https://x.com/${encodeURIComponent(username)}`
    const preview = await fetchUrlPreview(profileUrl, {
      fetchImpl: this.fetchImpl,
      lookup: this.lookup,
      timeoutMs: LOOKUP_TIMEOUT_MS,
      maxRedirects: 1,
      maxHtmlBytes: MAX_PROFILE_HTML_BYTES,
    }).catch(() => null)

    if (!preview) {
      return unavailable()
    }

    const avatarUrl = normalizeXAvatarUrl(preview.authorPhotoUrl)
    if (!avatarUrl) {
      return notFound()
    }

    const image = await fetchBinary(avatarUrl, {
      fetchImpl: this.fetchImpl,
      lookup: this.lookup,
      timeoutMs: LOOKUP_TIMEOUT_MS,
      maxRedirects: 1,
      maxBytes: MAX_PROFILE_PHOTO_BYTES,
      allowedContentTypes: ["image/jpeg", "image/png", "image/webp"],
    }).catch(() => null)

    if (!image || !isAllowedXAvatarUrl(image.finalUrl)) {
      return unavailable()
    }

    return {
      status: ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_FOUND,
      photo: image.bytes,
      mimeType: image.contentType,
    }
  }

  private cached(key: string): GetExternalProfilePhotoResult | null {
    const entry = this.cache.get(key)
    if (!entry) {
      return null
    }
    this.cache.delete(key)
    if (entry.expiresAt <= this.now()) {
      return null
    }
    this.cache.set(key, entry)
    return entry.result
  }

  private store(key: string, result: GetExternalProfilePhotoResult, ttlMs: number): void {
    this.cache.delete(key)
    while (this.cache.size >= this.cacheCapacity) {
      const oldestKey = this.cache.keys().next().value
      if (typeof oldestKey !== "string") break
      this.cache.delete(oldestKey)
    }
    this.cache.set(key, { result, expiresAt: this.now() + ttlMs })
  }
}

export const externalProfilePhotoResolver = new ExternalProfilePhotoResolver()

export function normalizeExternalUsername(provider: ExternalProfileProvider, input: string): string | null {
  switch (provider) {
    case ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_X:
      return normalizeXUsername(input)
    case ExternalProfileProvider.EXTERNAL_PROFILE_PROVIDER_UNSPECIFIED:
    default:
      return null
  }
}

function normalizeXUsername(input: string): string | null {
  let candidate = input.trim()
  try {
    const url = new URL(candidate)
    const hostname = url.hostname.toLowerCase().replace(/^www\./, "")
    if (hostname === "x.com" || hostname === "twitter.com") {
      candidate = url.pathname.split("/").filter(Boolean)[0] ?? ""
    }
  } catch {
    // A plain handle is the expected input.
  }

  candidate = candidate.replace(/^@+/, "")
  return /^[A-Za-z0-9_]{1,15}$/.test(candidate) ? candidate : null
}

function normalizeXAvatarUrl(input: string | undefined): string | null {
  if (!input) {
    return null
  }
  try {
    const url = new URL(input)
    if (!isAllowedXAvatarUrl(url.toString())) {
      return null
    }
    url.pathname = url.pathname.replace(/_(?:normal|200x200)(\.[A-Za-z0-9]+)$/i, "_400x400$1")
    url.search = ""
    return url.toString()
  } catch {
    return null
  }
}

function isAllowedXAvatarUrl(input: string): boolean {
  try {
    const url = new URL(input)
    return url.protocol === "https:" && url.hostname === "pbs.twimg.com" && url.pathname.startsWith("/profile_images/")
  } catch {
    return false
  }
}

function notFound(): GetExternalProfilePhotoResult {
  return {
    status: ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_NOT_FOUND,
    photo: new Uint8Array(),
    mimeType: "",
  }
}

function unavailable(): GetExternalProfilePhotoResult {
  return {
    status: ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_UNAVAILABLE,
    photo: new Uint8Array(),
    mimeType: "",
  }
}
