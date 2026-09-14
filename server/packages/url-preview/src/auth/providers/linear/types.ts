import type { ParsedProviderUrl } from "../../types.js"

export type LinearParsedUrl = ParsedProviderUrl<
  "linear",
  "issue",
  {
    workspace: string
    identifier: string
  }
>

export type LinearPreviewResourceType = "linear.issue"
