import type { FetchImpl, UrlPreviewResult } from "../types.js"

export type PreviewAuthOwner =
  | { type: "space"; spaceId: number }
  | { type: "user"; userId: number }

export type PreviewCredential = {
  provider: string
  accessToken: string
  owner?: PreviewAuthOwner
  scopes?: readonly string[]
  externalWorkspaceId?: string
}

export type ParsedProviderUrl<
  Provider extends string = string,
  ResourceType extends string = string,
  Meta extends Record<string, unknown> = Record<string, unknown>,
> = {
  provider: Provider
  resourceType: ResourceType
  resourceId: string
  originalUrl: string
  normalizedUrl: string
  meta: Meta
}

export type AuthPreviewOptions = {
  fetchImpl?: FetchImpl
  timeoutMs?: number
  maxResponseBytes?: number
  maxTitleLength?: number
  maxDescriptionLength?: number
  maxSiteNameLength?: number
  userAgent?: string
}

export type AuthenticatedPreviewResult<
  ParsedUrl extends ParsedProviderUrl = ParsedProviderUrl,
> = UrlPreviewResult & {
  parsedUrl: ParsedUrl
  providerResourceType?: string
  providerResourceId?: string
}

export type AuthenticatedPreviewProvider<ParsedUrl extends ParsedProviderUrl = ParsedProviderUrl> = {
  provider: ParsedUrl["provider"]
  parseUrl(input: string): ParsedUrl | null
  fetch(
    parsedUrl: ParsedUrl,
    credential: PreviewCredential,
    options?: AuthPreviewOptions,
  ): Promise<AuthenticatedPreviewResult<ParsedUrl> | null>
}
