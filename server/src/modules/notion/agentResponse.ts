import { z } from "zod/v4"

export type NotionAgentResponse = {
  properties: Record<string, unknown>
  markdown: string | null
  icon: null
}

const notionAgentResponseSchema = z.object({
  properties: z.object({}).catchall(z.unknown()).optional().default({}),
  markdown: z.string().nullable().optional(),
  icon: z.unknown().optional(),
})

type NotionAgentRawResponse = z.infer<typeof notionAgentResponseSchema>

export function parseNotionAgentResponse(input: {
  parsed?: unknown
  content?: string | null
}): NotionAgentResponse {
  const parsedInput = input.parsed !== undefined ? input.parsed : parseRawContent(input.content)

  return normalizeNotionAgentResponse(notionAgentResponseSchema.parse(parsedInput))
}

function parseRawContent(content: string | null | undefined): unknown {
  if (!content) {
    throw new Error("Failed to generate task data")
  }

  return JSON.parse(content)
}

function normalizeMarkdown(markdown: string | null | undefined): NotionAgentResponse["markdown"] {
  if (typeof markdown !== "string") {
    return null
  }

  const normalized = markdown.trim()
  return normalized.length > 0 ? normalized : null
}

function normalizeNotionAgentResponse(value: NotionAgentRawResponse): NotionAgentResponse {
  return {
    properties: value.properties,
    markdown: normalizeMarkdown(value.markdown),
    icon: null,
  }
}
