import { Client } from "@notionhq/client"
import type {
  DataSourceObjectResponse,
  PageObjectResponse,
  SearchParameters,
  SearchResponse,
} from "@notionhq/client/build/src/api-endpoints"
import type { IntegrationAuthToken } from "@in/server/modules/integrations/authResolver"
import type { ExternalResourceRecord } from "./externalResources.effect"

const NOTION_API_VERSION = "2026-03-11"
const NOTION_TIMEOUT_MS = 2_500
const MAX_TITLE_LENGTH = 180

export async function searchNotionResources(
  connection: IntegrationAuthToken,
  query: string,
  limit: number,
): Promise<readonly ExternalResourceRecord[]> {
  if (connection.provider !== "notion") {
    throw new Error("Notion search received the wrong provider connection")
  }

  const notion = new Client({
    auth: connection.accessToken,
    notionVersion: NOTION_API_VERSION,
    retry: false,
    timeoutMs: NOTION_TIMEOUT_MS,
  })
  const response = await notion.search(notionSearchParameters(query, limit))

  return mapNotionSearchResponse(response).slice(0, limit)
}

export function notionSearchParameters(
  query: string,
  limit: number,
): SearchParameters {
  return {
    ...(query ? { query } : {}),
    sort: {
      direction: "descending",
      timestamp: "last_edited_time",
    },
    page_size: limit,
  }
}

export function mapNotionSearchResponse(
  response: SearchResponse,
): ExternalResourceRecord[] {
  const resources: ExternalResourceRecord[] = []
  for (const result of response.results) {
    if (result.object === "page" && isFullPage(result)) {
      const title = pageTitle(result)
      if (title) {
        resources.push({
          id: result.id,
          provider: "notion",
          kind: "page",
          title,
          url: result.url,
          subtitle: "Notion page",
          emoji: notionEmoji(result.icon),
        })
      }
      continue
    }

    if (result.object === "data_source" && isFullDataSource(result)) {
      const title = richTextPlain(result.title)
      if (title) {
        resources.push({
          id: result.id,
          provider: "notion",
          kind: "database",
          title,
          url: result.url,
          subtitle: "Notion database",
          emoji: notionEmoji(result.icon),
        })
      }
    }
  }

  // Partial search hits have neither a title nor canonical URL. Avoid one
  // extra provider request per row in the latency- and rate-limit-sensitive
  // autocomplete path.
  return resources
}

function isFullPage(
  value: { readonly object: "page"; readonly id: string },
): value is PageObjectResponse {
  return "properties" in value && "url" in value
}

function isFullDataSource(
  value: { readonly object: "data_source"; readonly id: string },
): value is DataSourceObjectResponse {
  return "title" in value && "url" in value
}

function pageTitle(page: PageObjectResponse): string | null {
  for (const property of Object.values(page.properties)) {
    if (property.type === "title") {
      const title = richTextPlain(property.title)
      if (title) return title
    }
  }
  return null
}

function richTextPlain(
  value: ReadonlyArray<{ readonly plain_text: string }>,
): string | null {
  const text = value
    .map((item) => item.plain_text)
    .join("")
    .replace(/\s+/g, " ")
    .trim()
  if (!text) return null
  return text.slice(0, MAX_TITLE_LENGTH)
}

function notionEmoji(
  icon: PageObjectResponse["icon"] | DataSourceObjectResponse["icon"],
): string | undefined {
  if (icon?.type !== "emoji") return undefined
  return icon.emoji.trim().slice(0, 16) || undefined
}
