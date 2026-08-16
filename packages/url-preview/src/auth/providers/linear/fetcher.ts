import {
  DEFAULT_SITE_NAME_LENGTH,
  DEFAULT_TITLE_LENGTH,
} from "../../../constants.js"
import { cleanField } from "../../../text.js"
import { fetchProviderJson, ProviderFetchError } from "../../safe-fetch.js"
import type { AuthenticatedPreviewResult, AuthPreviewOptions, PreviewCredential } from "../../types.js"
import type { LinearParsedUrl } from "./types.js"

const linearApiUrl = "https://api.linear.app/graphql"

export async function fetchLinearPreview(
  parsedUrl: LinearParsedUrl,
  credential: PreviewCredential,
  options: AuthPreviewOptions = {},
): Promise<AuthenticatedPreviewResult<LinearParsedUrl> | null> {
  try {
    const payload = await fetchProviderJson(linearApiUrl, {
      ...options,
      allowedHosts: ["api.linear.app"],
      method: "POST",
      maxRedirects: 0,
      headers: {
        Authorization: `Bearer ${credential.accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: "query IssuePreview($id: String!) { issue(id: $id) { identifier title url } }",
        variables: { id: parsedUrl.meta.identifier },
      }),
    })
    const issue = asRecord(asRecord(payload)?.["data"])?.["issue"]
    const record = asRecord(issue)
    const identifier = stringValue(record?.["identifier"])?.toUpperCase()
    const title = stringValue(record?.["title"])
    if (!record || identifier !== parsedUrl.meta.identifier || !title) return null

    const compactTitle = `${identifier} · ${title}`
    return {
      parsedUrl,
      providerResourceType: "linear.issue",
      providerResourceId: identifier,
      url: parsedUrl.normalizedUrl,
      finalUrl: parsedUrl.normalizedUrl,
      siteName: cleanField("Linear", options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH) ?? "Linear",
      title: cleanField(compactTitle, options.maxTitleLength ?? DEFAULT_TITLE_LENGTH) ?? undefined,
      mediaType: "article",
      provider: "linear",
    }
  } catch (error) {
    if (error instanceof ProviderFetchError && [400, 401, 403, 404].includes(error.status ?? 0)) {
      return null
    }
    throw error
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null
}
