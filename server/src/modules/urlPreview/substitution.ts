import type { AuthenticatedPreviewResult, UrlPreviewResult } from "@inline-chat/url-preview"

type SubstitutionMetadata = UrlPreviewResult & Pick<AuthenticatedPreviewResult, "providerResourceType">

export type UrlPreviewSubstitution =
  | { canSubstitute: false }
  | { canSubstitute: true; title: string }

const maxProviderTitleLength = 120

export function resolveUrlPreviewSubstitution(metadata: SubstitutionMetadata): UrlPreviewSubstitution {
  const title = metadata.title?.trim()
  if (!title) return { canSubstitute: false }

  if (metadata.provider === "notion") {
    return supportedProviderTitle(metadata.providerResourceType, ["notion.page", "notion.database", "notion.data_source"], title)
  }

  if (metadata.provider === "linear") {
    return supportedProviderTitle(metadata.providerResourceType, ["linear.issue"], title)
  }

  return githubSubstitution(metadata.url, metadata.finalUrl, title)
}

function supportedProviderTitle(
  resourceType: string | undefined,
  allowedTypes: readonly string[],
  title: string,
): UrlPreviewSubstitution {
  if (!resourceType || !allowedTypes.includes(resourceType) || title.length > maxProviderTitleLength) {
    return { canSubstitute: false }
  }
  return { canSubstitute: true, title }
}

function githubSubstitution(urlString: string, finalUrlString: string, previewTitle: string): UrlPreviewSubstitution {
  const original = parseCleanGitHubUrl(urlString)
  const final = parseCleanGitHubUrl(finalUrlString)
  if (!original || !final || original.identity !== final.identity) return { canSubstitute: false }

  const repositoryIdentity = `${original.owner}/${original.repository}`
  if (!previewTitle.toLowerCase().includes(repositoryIdentity.toLowerCase())) {
    return { canSubstitute: false }
  }

  return {
    canSubstitute: true,
    title: original.number == null ? repositoryIdentity : `${repositoryIdentity}#${original.number}`,
  }
}

type GitHubResource = {
  identity: string
  owner: string
  repository: string
  number?: string
}

function parseCleanGitHubUrl(input: string): GitHubResource | null {
  let url: URL
  try {
    url = new URL(input)
  } catch {
    return null
  }
  if (
    url.protocol !== "https:" ||
    url.hostname.toLowerCase() !== "github.com" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    return null
  }

  const segments = url.pathname.split("/").filter(Boolean)
  if (segments.some((segment) => decodeURIComponentSafe(segment) !== segment)) return null
  const [owner, repository, kind, number] = segments
  if (!owner || !repository || reservedGitHubOwners.has(owner.toLowerCase())) return null

  if (segments.length === 2) {
    return { identity: `${owner.toLowerCase()}/${repository.toLowerCase()}`, owner, repository }
  }
  if (
    segments.length === 4 &&
    (kind === "issues" || kind === "pull") &&
    number != null &&
    /^[1-9]\d*$/.test(number)
  ) {
    return {
      identity: `${owner.toLowerCase()}/${repository.toLowerCase()}/${kind}/${number}`,
      owner,
      repository,
      number,
    }
  }
  return null
}

function decodeURIComponentSafe(value: string): string | null {
  try {
    return decodeURIComponent(value)
  } catch {
    return null
  }
}

const reservedGitHubOwners = new Set([
  "about", "collections", "contact", "customer-stories", "enterprise", "events", "explore",
  "features", "login", "marketplace", "new", "notifications", "orgs", "organizations", "pricing",
  "readme", "search", "security", "settings", "site", "sponsors", "topics", "trending", "users",
])
