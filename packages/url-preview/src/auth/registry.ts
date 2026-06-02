import { notionProvider } from "./providers/notion/index.js"
import type {
  AuthenticatedPreviewProvider,
  AuthenticatedPreviewResult,
  AuthPreviewOptions,
  ParsedProviderUrl,
  PreviewCredential,
} from "./types.js"

export const authenticatedPreviewProviders: readonly AuthenticatedPreviewProvider[] = [
  notionProvider as AuthenticatedPreviewProvider,
]

export function parseAuthenticatedPreviewUrl(input: string): ParsedProviderUrl | null {
  for (const provider of authenticatedPreviewProviders) {
    const parsed = provider.parseUrl(input)
    if (parsed) {
      return parsed
    }
  }

  return null
}

export async function fetchAuthenticatedUrlPreview(
  parsedUrl: ParsedProviderUrl,
  credential: PreviewCredential,
  options: AuthPreviewOptions = {},
): Promise<AuthenticatedPreviewResult | null> {
  if (credential.provider !== parsedUrl.provider) {
    return null
  }

  const provider = authenticatedPreviewProviders.find((candidate) => candidate.provider === parsedUrl.provider)
  if (!provider) {
    return null
  }

  return provider.fetch(parsedUrl, credential, options)
}
