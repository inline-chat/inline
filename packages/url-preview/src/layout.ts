import type { PreviewLayout, PreviewMediaType, PreviewProvider } from "./types.js"

export type PreviewLayoutPolicyInput = {
  url: string
  finalUrl?: string | null
  provider?: PreviewProvider | null
  mediaType?: PreviewMediaType | null
  mediaKind?: string | null
  hasCardContent?: boolean | null
  hasPhoto?: boolean | null
  hasLargeMedia?: boolean | null
  showLargeMedia?: boolean | null
  urlCount?: number | null
}

export type ResolvedPreviewLayout = {
  hasLargeMedia: boolean | null
  showLargeMedia: boolean | null
}

type PreviewLayoutRule = {
  id: string
  hosts?: readonly string[]
  providers?: readonly string[]
  mediaTypes?: readonly PreviewMediaType[]
  mediaKinds?: readonly string[]
  requireSingleUrl?: boolean
  allowTextCard?: boolean
  showLargeMedia: boolean
}

const largePreviewLayoutRules: readonly PreviewLayoutRule[] = [
  {
    id: "youtube-single-link",
    hosts: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
    providers: ["youtube"],
    requireSingleUrl: true,
    showLargeMedia: true,
  },
  {
    id: "x-single-link",
    hosts: ["x.com", "twitter.com"],
    providers: ["x"],
    requireSingleUrl: true,
    allowTextCard: true,
    showLargeMedia: true,
  },
]

export function previewLayout(media: { kind: string }): PreviewLayout {
  const hasLargeMedia = media.kind === "external_video" || media.kind === "embed" || media.kind === "photo"
  return {
    hasLargeMedia,
    showLargeMedia: media.kind === "external_video" || media.kind === "embed",
  }
}

export function textCardLayout(provider: PreviewProvider, hasCardContent: boolean): PreviewLayout | undefined {
  if (provider !== "x" || !hasCardContent) {
    return undefined
  }

  return {
    hasLargeMedia: true,
    showLargeMedia: true,
  }
}

export function resolvePreviewLayout(input: PreviewLayoutPolicyInput): ResolvedPreviewLayout {
  const rule = largePreviewLayoutRules.find((item) => matchesRule(item, input))
  if (!rule) {
    return {
      hasLargeMedia: input.hasLargeMedia ?? null,
      showLargeMedia: input.showLargeMedia ?? null,
    }
  }

  const hasLargeMedia = inferHasLargeMedia(input, rule) ?? false
  const canShowLarge = hasLargeMedia && (!rule.requireSingleUrl || input.urlCount == null || input.urlCount === 1)

  return {
    hasLargeMedia,
    showLargeMedia: rule.showLargeMedia && canShowLarge,
  }
}

function matchesRule(rule: PreviewLayoutRule, input: PreviewLayoutPolicyInput): boolean {
  return (
    matchesHosts(rule.hosts, input.url) ||
    matchesHosts(rule.hosts, input.finalUrl ?? undefined) ||
    matchesString(rule.providers, input.provider) ||
    matchesString(rule.mediaTypes, input.mediaType) ||
    matchesString(rule.mediaKinds, input.mediaKind)
  )
}

function inferHasLargeMedia(input: PreviewLayoutPolicyInput, rule: PreviewLayoutRule): boolean | null {
  if (input.hasLargeMedia != null) {
    return input.hasLargeMedia
  }

  if (input.hasPhoto === true) {
    return true
  }

  switch (input.mediaKind) {
    case "photo":
    case "video":
    case "external_video":
    case "embed":
      return true
    default:
      break
  }

  if (rule.allowTextCard && input.hasCardContent === true) {
    return true
  }

  return null
}

function matchesHosts(hosts: readonly string[] | undefined, url: string | undefined): boolean {
  const host = normalizedHost(url)
  if (!host || !hosts) {
    return false
  }

  return hosts.some((item) => host === item || host.endsWith(`.${item}`))
}

function matchesString(values: readonly string[] | undefined, value: string | null | undefined): boolean {
  if (!values || !value) {
    return false
  }

  const normalized = value.trim().toLowerCase()
  return values.includes(normalized)
}

function normalizedHost(value: string | undefined): string | null {
  if (!value) {
    return null
  }

  try {
    return new URL(value).hostname.toLowerCase().replace(/^www\./, "")
  } catch {
    return null
  }
}
