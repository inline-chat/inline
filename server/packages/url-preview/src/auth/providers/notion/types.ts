import type { ParsedProviderUrl } from "../../types.js"

export type NotionParsedResourceType = "unknown" | "block"

export type NotionParsedUrl = ParsedProviderUrl<
  "notion",
  NotionParsedResourceType,
  {
    host: string
  }
>

export type NotionPreviewResourceType =
  | "notion.page"
  | "notion.database"
  | "notion.data_source"
  | "notion.file"
  | "notion.block"

export type NotionObjectKind = "page" | "database" | "data_source" | "block"
