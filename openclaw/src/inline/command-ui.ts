import type { ReplyPayload } from "openclaw/plugin-sdk/reply-payload"
import { sanitizeInlineActionLabel } from "./outbound-sanitize.js"

export type InlineReplyMarkupButton = {
  text: string
  callback_data: string
}

type InlineChannelData = ReplyPayload["channelData"]

type ProviderInfo = {
  id: string
  count: number
}

const MODEL_LABEL_LIMIT = 38

function inlineChannelData(buttons: InlineReplyMarkupButton[][]): InlineChannelData {
  return { inline: { buttons } }
}

function safeLabel(raw: string): string {
  return sanitizeInlineActionLabel(raw) ?? "Option"
}

function truncateStart(value: string, maxLen: number): string {
  if (value.length <= maxLen) return value
  return `…${value.slice(-(maxLen - 1))}`
}

function isCurrentModel(params: {
  provider: string
  model: string
  currentModel?: string
}): boolean {
  const current = params.currentModel?.trim()
  if (!current) return false
  return current.includes("/")
    ? current === `${params.provider}/${params.model}`
    : current === params.model
}

function buildInlineCommandsPaginationButtons(params: {
  currentPage: number
  totalPages: number
  agentId?: string
}): InlineReplyMarkupButton[][] {
  const suffix = params.agentId ? `:${params.agentId}` : ""
  const buttons: InlineReplyMarkupButton[] = []
  if (params.currentPage > 1) {
    buttons.push({
      text: "◀ Prev",
      callback_data: `commands_page_${params.currentPage - 1}${suffix}`,
    })
  }
  buttons.push({
    text: `${params.currentPage}/${params.totalPages}`,
    callback_data: `commands_page_noop${suffix}`,
  })
  if (params.currentPage < params.totalPages) {
    buttons.push({
      text: "Next ▶",
      callback_data: `commands_page_${params.currentPage + 1}${suffix}`,
    })
  }
  return [buttons]
}

export function parseInlineCommandsPageCallback(
  raw: string | undefined,
): { page: number | "noop"; agentId?: string } | null {
  const match = raw?.trim().match(/^commands_page_(\d+|noop)(?::(.+))?$/)
  if (!match?.[1]) return null
  const agentId = match[2]?.trim()
  if (match[1] === "noop") {
    return {
      page: "noop",
      ...(agentId ? { agentId } : {}),
    }
  }
  const page = Number.parseInt(match[1], 10)
  if (!Number.isFinite(page) || page < 1) return null
  return {
    page,
    ...(agentId ? { agentId } : {}),
  }
}

export function buildInlineCommandsListChannelData(params: {
  currentPage: number
  totalPages: number
  agentId?: string
}): InlineChannelData | null {
  if (params.totalPages <= 1) return null
  return inlineChannelData(buildInlineCommandsPaginationButtons(params))
}

export function buildInlineModelProviderButtons(
  providers: ProviderInfo[],
): InlineReplyMarkupButton[][] {
  const rows: InlineReplyMarkupButton[][] = []
  for (let index = 0; index < providers.length; index += 2) {
    const slice = providers.slice(index, index + 2)
    rows.push(
      slice.map((provider) => ({
        text: safeLabel(`${provider.id} (${provider.count})`),
        callback_data: `mdl_list_${provider.id}_1`,
      })),
    )
  }
  return rows
}

export function buildInlineModelsMenuChannelData(params: {
  providers: ProviderInfo[]
}): InlineChannelData | null {
  if (params.providers.length === 0) return null
  return inlineChannelData(buildInlineModelProviderButtons(params.providers))
}

export function buildInlineModelsProviderChannelData(params: {
  providers: ProviderInfo[]
}): InlineChannelData | null {
  return buildInlineModelsMenuChannelData(params)
}

export function buildInlineModelsAddProviderChannelData(params: {
  providers: Array<{ id: string }>
}): InlineChannelData | null {
  if (params.providers.length === 0) return null
  return inlineChannelData(
    params.providers.map((provider) => [
      {
        text: safeLabel(provider.id),
        callback_data: `/models add ${provider.id}`,
      },
    ]),
  )
}

export function buildInlineModelsListChannelData(params: {
  provider: string
  models: readonly string[]
  currentModel?: string
  currentPage: number
  totalPages: number
  pageSize?: number
  modelNames?: ReadonlyMap<string, string>
}): InlineChannelData | null {
  const pageSize = params.pageSize ?? 8
  if (params.models.length === 0) {
    return inlineChannelData([[{ text: "<< Back", callback_data: "mdl_back" }]])
  }

  const rows: InlineReplyMarkupButton[][] = []
  const start = (params.currentPage - 1) * pageSize
  const end = Math.min(start + pageSize, params.models.length)
  for (const model of params.models.slice(start, end)) {
    const fallbackLabel = model.includes("/") ? `${params.provider}/${model}` : model
    const display = truncateStart(
      params.modelNames?.get(`${params.provider}/${model}`) ?? fallbackLabel,
      MODEL_LABEL_LIMIT,
    )
    const label = isCurrentModel({
      provider: params.provider,
      model,
      ...(params.currentModel ? { currentModel: params.currentModel } : {}),
    })
      ? `${display} ✓`
      : display
    rows.push([
      {
        text: safeLabel(label),
        callback_data: `mdl_sel_${params.provider}/${model}`,
      },
    ])
  }

  if (params.totalPages > 1) {
    const pagination: InlineReplyMarkupButton[] = []
    if (params.currentPage > 1) {
      pagination.push({
        text: "◀ Prev",
        callback_data: `mdl_list_${params.provider}_${params.currentPage - 1}`,
      })
    }
    pagination.push({
      text: `${params.currentPage}/${params.totalPages}`,
      callback_data: `mdl_list_${params.provider}_${params.currentPage}`,
    })
    if (params.currentPage < params.totalPages) {
      pagination.push({
        text: "Next ▶",
        callback_data: `mdl_list_${params.provider}_${params.currentPage + 1}`,
      })
    }
    rows.push(pagination)
  }

  rows.push([{ text: "<< Back", callback_data: "mdl_back" }])
  return inlineChannelData(rows)
}

export function buildInlineModelBrowseChannelData(): InlineChannelData {
  return inlineChannelData([[{ text: "Browse providers", callback_data: "mdl_prov" }]])
}
