import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import { readFile } from "node:fs/promises"
import path from "node:path"
import type { InlineConfig } from "./config-schema.js"
import { InlineConfigSchema } from "./config-schema.js"

export type ResolvedInlineAccount = {
  accountId: string
  name: string
  enabled: boolean
  configured: boolean
  baseUrl: string | null
  token: string | null
  tokenFile: string | null
  config: InlineConfig
}

const DEFAULT_BASE_URL = "https://api.inline.chat"

function isDotEnvPath(filePath: string): boolean {
  const base = path.basename(filePath.trim())
  return base === ".env" || base.startsWith(".env.")
}

function readInlineConfig(cfg: OpenClawConfig): InlineConfig {
  const raw = (cfg.channels?.inline ?? {}) as unknown
  const result = InlineConfigSchema.safeParse(raw)
  if (!result.success) {
    // OpenClaw validates config against channel schema before calling adapters,
    // but keep a defensive fallback for programmatic usage.
    return InlineConfigSchema.parse({})
  }
  return result.data
}

export function listInlineAccountIds(cfg: OpenClawConfig): string[] {
  const config = readInlineConfig(cfg)
  const ids = new Set<string>()
  const hasBase = Boolean(
    (config.token ?? "").trim() ||
      (config.tokenFile ?? "").trim() ||
      (config.baseUrl ?? "").trim(),
  )
  if (hasBase) {
    ids.add(DEFAULT_ACCOUNT_ID)
  }
  for (const key of Object.keys(config.accounts ?? {})) {
    const normalized = key.trim()
    if (normalized) ids.add(normalized)
  }
  return [...ids]
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
  const requested = (params.accountId ?? DEFAULT_ACCOUNT_ID).trim() || DEFAULT_ACCOUNT_ID

  const accountOverride = config.accounts?.[requested] ?? null
  const { accounts: _accounts, ...base } = config
  const effective: InlineConfig = accountOverride ? ({ ...base, ...accountOverride } as InlineConfig) : config

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

  if (isDotEnvPath(tokenFile)) {
    // AGENTS.md: never read .env contents.
    throw new Error(`Refusing to read tokenFile from ${tokenFile} (disallowed: .env)`)
  }

  const raw = await readFile(tokenFile, "utf8")
  const token = raw.trim()
  if (!token) throw new Error(`Inline tokenFile is empty: ${tokenFile}`)
  return token
}
