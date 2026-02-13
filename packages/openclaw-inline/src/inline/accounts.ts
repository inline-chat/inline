import { DEFAULT_ACCOUNT_ID, normalizeAccountId } from "openclaw/plugin-sdk"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import { readFile } from "node:fs/promises"
import type { InlineRuntimeConfig } from "./config-schema.js"
import { InlineRuntimeConfigSchema } from "./config-schema.js"

export type ResolvedInlineAccount = {
  accountId: string
  name: string
  enabled: boolean
  configured: boolean
  baseUrl: string | null
  token: string | null
  tokenFile: string | null
  config: InlineRuntimeConfig
}

const DEFAULT_BASE_URL = "https://api.inline.chat"

function normalizeInlineAccountId(raw: string | null | undefined): string {
  return normalizeAccountId(raw ?? DEFAULT_ACCOUNT_ID)
}

function readInlineConfig(cfg: OpenClawConfig): InlineRuntimeConfig {
  const raw = (cfg.channels?.inline ?? {}) as unknown
  const result = InlineRuntimeConfigSchema.safeParse(raw)
  if (!result.success) {
    return InlineRuntimeConfigSchema.parse({})
  }
  return result.data
}

export function listInlineAccountIds(cfg: OpenClawConfig): string[] {
  const config = readInlineConfig(cfg)
  const ids = new Set<string>()
  const hasBase = Boolean(
    (config.token ?? "").trim() ||
      (config.tokenFile ?? "").trim(),
  )
  if (hasBase) {
    ids.add(DEFAULT_ACCOUNT_ID)
  }
  for (const key of Object.keys(config.accounts ?? {})) {
    const normalized = normalizeInlineAccountId(key)
    if (normalized) ids.add(normalized)
  }
  return [...ids].sort((a, b) => a.localeCompare(b))
}

export function resolveDefaultInlineAccountId(cfg: OpenClawConfig): string {
  const ids = listInlineAccountIds(cfg)
  if (ids.includes(DEFAULT_ACCOUNT_ID)) return DEFAULT_ACCOUNT_ID
  return ids[0] ?? DEFAULT_ACCOUNT_ID
}

export function resolveInlineAccount(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): ResolvedInlineAccount {
  const config = readInlineConfig(params.cfg)
  const requested =
    params.accountId == null
      ? resolveDefaultInlineAccountId(params.cfg)
      : normalizeInlineAccountId(params.accountId)

  let accountOverride: InlineRuntimeConfig | null = null
  for (const [key, value] of Object.entries(config.accounts ?? {})) {
    if (!value) continue
    if (normalizeInlineAccountId(key) !== requested) continue
    accountOverride = value as InlineRuntimeConfig
    break
  }

  const { accounts: _accounts, ...base } = config
  const effective: InlineRuntimeConfig = accountOverride
    ? ({ ...base, ...accountOverride } as InlineRuntimeConfig)
    : config

  const enabled = effective.enabled ?? true

  const baseUrl = (effective.baseUrl ?? "").trim() || DEFAULT_BASE_URL
  const token = (effective.token ?? "").trim()
  const tokenFile = (effective.tokenFile ?? "").trim()
  const configured = Boolean(token || tokenFile)

  return {
    accountId: requested,
    name: effective.name?.trim() || requested,
    enabled,
    configured,
    baseUrl: baseUrl || null,
    token: token || null,
    tokenFile: tokenFile || null,
    config: effective,
  }
}

export async function resolveInlineToken(account: ResolvedInlineAccount): Promise<string> {
  const inlineToken = (account.token ?? "").trim()
  if (inlineToken) return inlineToken

  const tokenFile = (account.tokenFile ?? "").trim()
  if (!tokenFile) throw new Error("Inline token missing (set channels.inline.token or channels.inline.tokenFile)")

  const raw = await readFile(tokenFile, "utf8")
  const token = raw.trim()
  if (!token) throw new Error(`Inline tokenFile is empty: ${tokenFile}`)
  return token
}
