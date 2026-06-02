import {
  DEFAULT_DESCRIPTION_LENGTH,
  DEFAULT_SITE_NAME_LENGTH,
  DEFAULT_TITLE_LENGTH,
} from "../../../constants.js"
import { cleanField } from "../../../text.js"
import type { AuthenticatedPreviewResult, AuthPreviewOptions, PreviewCredential } from "../../types.js"
import { fetchProviderJson, ProviderFetchError } from "../../safe-fetch.js"
import type { NotionParsedUrl, NotionPreviewResourceType } from "./types.js"

const notionApiHost = "api.notion.com"
const notionApiVersion = "2026-03-11"

export async function fetchNotionPreview(
  parsedUrl: NotionParsedUrl,
  credential: PreviewCredential,
  options: AuthPreviewOptions = {},
): Promise<AuthenticatedPreviewResult<NotionParsedUrl> | null> {
  const id = parsedUrl.resourceId

  if (parsedUrl.resourceType === "block") {
    const block = await tryGetNotionObject(`blocks/${encodeURIComponent(id)}`, credential, options)
    if (block === blocked) return null
    if (block) return buildBlockPreview(parsedUrl, block, options)
    return null
  }

  const page = await tryGetNotionObject(`pages/${encodeURIComponent(id)}`, credential, options)
  if (page === blocked) return null
  if (page) return buildPagePreview(parsedUrl, page, options)

  const database = await tryGetNotionObject(`databases/${encodeURIComponent(id)}`, credential, options)
  if (database === blocked) return null
  if (database) return buildDatabasePreview(parsedUrl, database, options)

  const dataSource = await tryGetNotionObject(`data_sources/${encodeURIComponent(id)}`, credential, options)
  if (dataSource === blocked) return null
  if (dataSource) return buildDataSourcePreview(parsedUrl, dataSource, options)

  return null
}

const blocked = Symbol("blocked")

async function tryGetNotionObject(
  path: string,
  credential: PreviewCredential,
  options: AuthPreviewOptions,
): Promise<Record<string, unknown> | null | typeof blocked> {
  try {
    const value = await fetchProviderJson(`https://${notionApiHost}/v1/${path}`, {
      ...options,
      allowedHosts: [notionApiHost],
      headers: {
        Authorization: `Bearer ${credential.accessToken}`,
        "Notion-Version": notionApiVersion,
      },
    })
    return asRecord(value)
  } catch (error) {
    if (error instanceof ProviderFetchError) {
      if (error.status === 401 || error.status === 403) {
        return blocked
      }
      if (error.status === 400 || error.status === 404) {
        return null
      }
    }
    throw error
  }
}

function buildPagePreview(
  parsedUrl: NotionParsedUrl,
  page: Record<string, unknown>,
  options: AuthPreviewOptions,
): AuthenticatedPreviewResult<NotionParsedUrl> | null {
  if (stringValue(page["object"]) !== "page") {
    return null
  }

  const title = pageTitle(page)
  const description = pageDescription(page)
  const hasFiles = pageFileNames(page).length > 0

  return basePreview(parsedUrl, {
    providerResourceType: "notion.page",
    title,
    description,
    mediaType: hasFiles ? "document" : "article",
    options,
  })
}

function buildDatabasePreview(
  parsedUrl: NotionParsedUrl,
  database: Record<string, unknown>,
  options: AuthPreviewOptions,
): AuthenticatedPreviewResult<NotionParsedUrl> | null {
  if (stringValue(database["object"]) !== "database") {
    return null
  }

  const title = richTextPlain(database["title"])
  const description = richTextPlain(database["description"])

  return basePreview(parsedUrl, {
    providerResourceType: "notion.database",
    title,
    description,
    mediaType: "article",
    options,
  })
}

function buildDataSourcePreview(
  parsedUrl: NotionParsedUrl,
  dataSource: Record<string, unknown>,
  options: AuthPreviewOptions,
): AuthenticatedPreviewResult<NotionParsedUrl> | null {
  if (stringValue(dataSource["object"]) !== "data_source") {
    return null
  }

  const title = richTextPlain(dataSource["title"])
  const description = richTextPlain(dataSource["description"])

  return basePreview(parsedUrl, {
    providerResourceType: "notion.data_source",
    title,
    description,
    mediaType: "article",
    options,
  })
}

function buildBlockPreview(
  parsedUrl: NotionParsedUrl,
  block: Record<string, unknown>,
  options: AuthPreviewOptions,
): AuthenticatedPreviewResult<NotionParsedUrl> | null {
  if (stringValue(block["object"]) !== "block") {
    return null
  }

  const type = stringValue(block["type"])
  const blockValue = type ? asRecord(block[type]) : null
  const title = fileLikeBlockTitle(type, blockValue) ?? blockCaption(blockValue)
  const providerResourceType = fileLikeTypes.has(type ?? "") ? "notion.file" : "notion.block"
  const mediaType = fileLikeMediaType(type)

  return basePreview(parsedUrl, {
    providerResourceType,
    title,
    description: undefined,
    mediaType,
    options,
  })
}

function basePreview(
  parsedUrl: NotionParsedUrl,
  input: {
    providerResourceType: NotionPreviewResourceType
    title?: string | null
    description?: string | null
    mediaType: "article" | "image" | "video" | "document"
    options: AuthPreviewOptions
  },
): AuthenticatedPreviewResult<NotionParsedUrl> {
  return {
    parsedUrl,
    providerResourceType: input.providerResourceType,
    providerResourceId: parsedUrl.resourceId,
    url: parsedUrl.normalizedUrl,
    finalUrl: parsedUrl.normalizedUrl,
    siteName: cleanField("Notion", input.options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH) ?? "Notion",
    title: cleanField(input.title, input.options.maxTitleLength ?? DEFAULT_TITLE_LENGTH) ?? undefined,
    description: cleanField(input.description, input.options.maxDescriptionLength ?? DEFAULT_DESCRIPTION_LENGTH) ?? undefined,
    mediaType: input.mediaType,
    provider: "notion",
  }
}

function pageTitle(page: Record<string, unknown>): string | null {
  const properties = asRecord(page["properties"])
  if (!properties) {
    return null
  }

  for (const property of Object.values(properties)) {
    const record = asRecord(property)
    if (record && stringValue(record["type"]) === "title") {
      const title = richTextPlain(record["title"])
      if (title) {
        return title
      }
    }
  }

  return null
}

function pageDescription(page: Record<string, unknown>): string | null {
  const properties = asRecord(page["properties"])
  if (!properties) {
    return null
  }

  for (const [name, property] of Object.entries(properties)) {
    const normalized = name.trim().toLowerCase()
    if (normalized !== "description" && normalized !== "summary") {
      continue
    }

    const record = asRecord(property)
    if (record && stringValue(record["type"]) === "rich_text") {
      const description = richTextPlain(record["rich_text"])
      if (description) {
        return description
      }
    }
  }

  return null
}

function pageFileNames(page: Record<string, unknown>): string[] {
  const properties = asRecord(page["properties"])
  if (!properties) {
    return []
  }

  const names: string[] = []
  for (const property of Object.values(properties)) {
    const record = asRecord(property)
    if (!record || stringValue(record["type"]) !== "files") {
      continue
    }

    for (const file of arrayValue(record["files"])) {
      const name = notionFileName(file)
      if (name) {
        names.push(name)
      }
    }
  }

  return names
}

function richTextPlain(value: unknown): string | null {
  const text = arrayValue(value)
    .map((item) => {
      const record = asRecord(item)
      if (!record) return ""
      return stringValue(record["plain_text"]) ?? stringValue(asRecord(record["text"])?.["content"]) ?? ""
    })
    .join("")
    .trim()

  return text || null
}

function fileLikeBlockTitle(type: string | undefined, blockValue: Record<string, unknown> | null): string | null {
  if (!type || !blockValue || !fileLikeTypes.has(type)) {
    return null
  }

  return notionFileName(blockValue) ?? blockCaption(blockValue)
}

function blockCaption(blockValue: Record<string, unknown> | null): string | null {
  if (!blockValue) {
    return null
  }
  return richTextPlain(blockValue["caption"])
}

function fileLikeMediaType(type: string | undefined): "article" | "image" | "video" | "document" {
  switch (type) {
    case "image":
      return "image"
    case "video":
      return "video"
    case "file":
    case "pdf":
    case "audio":
      return "document"
    default:
      return "article"
  }
}

function notionFileName(value: unknown): string | null {
  const record = asRecord(value)
  if (!record) {
    return null
  }

  const name = stringValue(record["name"])
  if (name) {
    return name
  }

  const directUrl = stringValue(record["url"])
  if (directUrl) {
    return fileNameFromUrl(directUrl)
  }

  const nested = asRecord(record[stringValue(record["type"]) ?? ""])
  const nestedName = stringValue(nested?.["name"])
  if (nestedName) {
    return nestedName
  }

  const nestedUrl = stringValue(nested?.["url"])
  if (nestedUrl) {
    return fileNameFromUrl(nestedUrl)
  }

  const externalUrl = stringValue(asRecord(record["external"])?.["url"])
  if (externalUrl) {
    return fileNameFromUrl(externalUrl)
  }

  return null
}

function fileNameFromUrl(input: string): string | null {
  try {
    const url = new URL(input)
    const segment = url.pathname.split("/").filter(Boolean).at(-1)
    return segment ? decodeURIComponent(segment) : null
  } catch {
    return null
  }
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined
}

const fileLikeTypes = new Set(["file", "image", "pdf", "video", "audio"])
