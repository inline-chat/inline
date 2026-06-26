import { allMeta, type ParsedHtml } from "./html.js"
import { normalizeMetadataUrl } from "./normalize.js"
import type { PreviewProvider } from "./types.js"

export const metadataImageKeys = [
  "og:image:secure_url",
  "og:image:url",
  "og:image",
  "twitter:image",
  "twitter:image:src",
]

type PreviewImageRoleRule = {
  id: string
  provider: PreviewProvider
  previewHosts: readonly string[]
  authorImageHosts: readonly string[]
  authorPathPrefixes: readonly string[]
  primaryImageHosts: readonly string[]
  primaryPathPrefixes: readonly string[]
}

const imageRoleRules: readonly PreviewImageRoleRule[] = [
  {
    id: "x-twitter-images",
    provider: "x",
    previewHosts: ["x.com", "twitter.com"],
    authorImageHosts: ["pbs.twimg.com", "abs.twimg.com"],
    authorPathPrefixes: ["/profile_images/", "/sticky/default_profile_images/"],
    primaryImageHosts: ["pbs.twimg.com"],
    primaryPathPrefixes: [
      "/media/",
      "/card_img/",
      "/ext_tw_video_thumb/",
      "/tweet_video_thumb/",
      "/amplify_video_thumb/",
    ],
  },
  {
    id: "youtube-images",
    provider: "youtube",
    previewHosts: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
    authorImageHosts: ["yt3.ggpht.com", "yt3.googleusercontent.com"],
    authorPathPrefixes: ["/"],
    primaryImageHosts: ["i.ytimg.com", "img.youtube.com"],
    primaryPathPrefixes: ["/vi/", "/vi_webp/", "/sb/", "/an_webp/"],
  },
]

export function metadataImageUrls(meta: ParsedHtml, finalUrl: string): string[] {
  const urls: string[] = []
  const seen = new Set<string>()

  for (const value of allMeta(meta, metadataImageKeys)) {
    const url = normalizeMetadataUrl(value, finalUrl)
    if (!url || seen.has(url)) {
      continue
    }
    urls.push(url)
    seen.add(url)
  }

  return urls
}

export function selectPreviewImage(
  originalUrl: string,
  finalUrl: string,
  imageUrls: readonly string[],
): { primaryUrl?: string; authorPhotoUrl?: string } {
  const rule = imageRuleForPreview(originalUrl, finalUrl)
  if (!rule) {
    return { primaryUrl: imageUrls[0] }
  }

  let authorPhotoUrl: string | undefined
  for (const imageUrl of imageUrls) {
    const role = imageRole(rule, imageUrl)
    if (role === "author") {
      authorPhotoUrl ??= imageUrl
      continue
    }

    return { primaryUrl: imageUrl, authorPhotoUrl }
  }

  return { authorPhotoUrl }
}

export function previewProviderFromImageRules(
  originalUrl: string,
  finalUrl: string,
): PreviewProvider | undefined {
  return imageRuleForPreview(originalUrl, finalUrl)?.provider
}

export function isPreviewAuthorImageUrl(previewUrl: string, imageUrl: string): boolean {
  const rule = imageRuleForPreview(previewUrl, previewUrl)
  return rule ? imageRole(rule, imageUrl) === "author" : false
}

function imageRuleForPreview(originalUrl: string, finalUrl: string): PreviewImageRoleRule | undefined {
  return imageRoleRules.find(
    (item) => isHostMatch(item.previewHosts, originalUrl) || isHostMatch(item.previewHosts, finalUrl),
  )
}

function imageRole(rule: PreviewImageRoleRule, imageUrl: string): "author" | "primary" {
  if (matchesImagePath(rule.authorImageHosts, rule.authorPathPrefixes, imageUrl)) {
    return "author"
  }

  if (matchesImagePath(rule.primaryImageHosts, rule.primaryPathPrefixes, imageUrl)) {
    return "primary"
  }

  return "primary"
}

function matchesImagePath(hosts: readonly string[], pathPrefixes: readonly string[], url: string): boolean {
  const parsed = parseUrl(url)
  if (!parsed || !isHostMatch(hosts, url)) {
    return false
  }

  return pathPrefixes.some((prefix) => parsed.pathname.startsWith(prefix))
}

function isHostMatch(hosts: readonly string[], url: string): boolean {
  const parsed = parseUrl(url)
  if (!parsed) {
    return false
  }

  const host = parsed.hostname.toLowerCase().replace(/^www\./, "")
  return hosts.some((item) => host === item || host.endsWith(`.${item}`))
}

function parseUrl(url: string): URL | null {
  try {
    return new URL(url)
  } catch {
    return null
  }
}
