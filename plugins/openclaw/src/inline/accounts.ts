import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { tryReadSecretFileSync } from "openclaw/plugin-sdk/channel-core"
import { resolveDefaultSecretProviderAlias } from "openclaw/plugin-sdk/provider-auth"
import {
  normalizeSecretInputString,
  resolveSecretInputString,
} from "openclaw/plugin-sdk/secret-input-runtime"
import type { InlineRuntimeConfig } from "./config-schema.js"
import { InlineRuntimeConfigSchema } from "./config-schema.js"
import { DEFAULT_ACCOUNT_ID, normalizeAccountId } from "../openclaw-compat.js"

export type ResolvedInlineAccount = {
  accountId: string
  name: string
  enabled: boolean
  configured: boolean
  baseUrl: string | null
  token: string | null
  tokenFile: string | null
  tokenSource: "config" | "env" | "file" | "none"
  tokenConfigured: boolean
  reactionNotifications: InlineRuntimeConfig["reactionNotifications"]
  reactionAllowlist: InlineRuntimeConfig["reactionAllowlist"]
  config: InlineRuntimeConfig
}

export type InlineCredentialStatus = "available" | "configured_unavailable" | "missing"

export type InspectedInlineAccount = {
  accountId: string
  name: string
  enabled: boolean
  configured: boolean
  baseUrl: string | null
  token: string | null
  tokenFile: string | null
  tokenSource: "config" | "env" | "file" | "none"
  tokenStatus: InlineCredentialStatus
  tokenConfigured: boolean
  config: InlineRuntimeConfig
}

const DEFAULT_BASE_URL = "https://api.inline.chat"
const INLINE_ENV_TOKEN_KEYS = ["INLINE_TOKEN", "INLINE_BOT_TOKEN"] as const

type ResolvedInlineTokenInput = {
  configured: boolean
  token: string | null
  source: "config" | "env" | "none"
}

type SelectedInlineCredentials = {
  tokenInput: ResolvedInlineTokenInput
  tokenFile: string
}

export function resolveInlineEnvToken(env: NodeJS.ProcessEnv = process.env): string | null {
  for (const key of INLINE_ENV_TOKEN_KEYS) {
    const token = env[key]?.trim()
    if (token) return token
  }
  return null
}

function normalizeString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

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

function canResolveEnvSecretRef(params: {
  cfg: Pick<OpenClawConfig, "secrets">
  provider: string
  id: string
}): boolean {
  const provider = params.cfg.secrets?.providers?.[params.provider]
  if (!provider) {
    return params.provider === resolveDefaultSecretProviderAlias(params.cfg, "env")
  }
  if (provider.source !== "env") {
    return false
  }
  return !provider.allowlist || provider.allowlist.includes(params.id)
}

function resolveInlineTokenInput(params: {
  cfg: OpenClawConfig
  value: unknown
  path: string
  env?: NodeJS.ProcessEnv
}): ResolvedInlineTokenInput {
  const resolved = resolveSecretInputString({
    value: params.value,
    path: params.path,
    mode: "inspect",
    ...(params.cfg.secrets?.defaults ? { defaults: params.cfg.secrets.defaults } : {}),
  })
  if (resolved.status === "available") {
    return {
      configured: true,
      token: resolved.value,
      source: "config",
    }
  }
  if (resolved.status === "missing") {
    return {
      configured: false,
      token: null,
      source: "none",
    }
  }
  if (
    resolved.ref.source === "env" &&
    canResolveEnvSecretRef({
      cfg: params.cfg,
      provider: resolved.ref.provider,
      id: resolved.ref.id,
    })
  ) {
    const envValue = normalizeSecretInputString((params.env ?? process.env)[resolved.ref.id])
    if (envValue) {
      return {
        configured: true,
        token: envValue,
        source: "env",
      }
    }
  }
  return {
    configured: true,
    token: null,
    source: resolved.ref.source === "env" ? "env" : "config",
  }
}

function missingInlineTokenInput(): ResolvedInlineTokenInput {
  return {
    configured: false,
    token: null,
    source: "none",
  }
}

export function listInlineAccountIds(
  cfg: OpenClawConfig,
  env: NodeJS.ProcessEnv = process.env,
): string[] {
  const config = readInlineConfig(cfg)
  const ids = new Set<string>()
  const hasBase = Boolean(
    resolveInlineTokenInput({
      cfg,
      value: config.token,
      path: "channels.inline.token",
      env,
    }).configured ||
      normalizeString(config.tokenFile) ||
      resolveInlineEnvToken(env),
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

function selectInlineCredentials(params: {
  cfg: OpenClawConfig
  config: InlineRuntimeConfig
  accountId: string
  accountOverride: InlineRuntimeConfig | null
  blockUnknownAccountFallback: boolean
  env?: NodeJS.ProcessEnv
}): SelectedInlineCredentials {
  if (params.blockUnknownAccountFallback) {
    return {
      tokenInput: missingInlineTokenInput(),
      tokenFile: "",
    }
  }

  const baseToken = resolveInlineTokenInput({
    cfg: params.cfg,
    value: params.config.token,
    path: "channels.inline.token",
    ...(params.env ? { env: params.env } : {}),
  })
  const baseTokenFile = normalizeString(params.config.tokenFile)

  if (!params.accountOverride) {
    return {
      tokenInput: baseToken,
      tokenFile: baseToken.token || baseToken.configured ? "" : baseTokenFile,
    }
  }

  const accountToken = resolveInlineTokenInput({
    cfg: params.cfg,
    value: params.accountOverride.token,
    path: `channels.inline.accounts.${params.accountId}.token`,
    ...(params.env ? { env: params.env } : {}),
  })
  if (accountToken.token || accountToken.configured) {
    return {
      tokenInput: accountToken,
      tokenFile: "",
    }
  }

  const accountTokenFile = normalizeString(params.accountOverride.tokenFile)
  if (accountTokenFile) {
    return {
      tokenInput: missingInlineTokenInput(),
      tokenFile: accountTokenFile,
    }
  }

  return {
    tokenInput: baseToken,
    tokenFile: baseToken.token || baseToken.configured ? "" : baseTokenFile,
  }
}

export function resolveDefaultInlineAccountId(cfg: OpenClawConfig): string {
  const ids = listInlineAccountIds(cfg)
  if (ids.includes(DEFAULT_ACCOUNT_ID)) return DEFAULT_ACCOUNT_ID
  return ids[0] ?? DEFAULT_ACCOUNT_ID
}

export function resolveInlineAccount(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  env?: NodeJS.ProcessEnv
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
  const hasExplicitAccounts = Object.keys(config.accounts ?? {}).length > 0
  const blockUnknownAccountFallback =
    requested !== DEFAULT_ACCOUNT_ID && hasExplicitAccounts && !accountOverride
  const { token: _token, tokenFile: _tokenFile, ...baseWithoutCredentials } = base
  const effective: InlineRuntimeConfig = accountOverride
    ? ({ ...base, ...accountOverride } as InlineRuntimeConfig)
    : blockUnknownAccountFallback
      ? (baseWithoutCredentials as InlineRuntimeConfig)
    : config

  const enabled = effective.enabled ?? true

  const baseUrl = (effective.baseUrl ?? "").trim() || DEFAULT_BASE_URL
  const credentials = selectInlineCredentials({
    cfg: params.cfg,
    config,
    accountId: requested,
    accountOverride,
    blockUnknownAccountFallback,
    ...(params.env ? { env: params.env } : {}),
  })
  const configuredToken = credentials.tokenInput
  const tokenFile = credentials.tokenFile
  const envToken = requested === DEFAULT_ACCOUNT_ID && !configuredToken.configured && !tokenFile
    ? resolveInlineEnvToken(params.env)
    : null
  const token = configuredToken.token || envToken || ""
  const configured = Boolean(token || tokenFile)
  const tokenSource = configuredToken.token || configuredToken.configured
    ? configuredToken.source
    : envToken
      ? "env"
      : tokenFile
        ? "file"
        : "none"

  return {
    accountId: requested,
    name: effective.name?.trim() || requested,
    enabled,
    configured,
    baseUrl: baseUrl || null,
    token: token || null,
    tokenFile: tokenFile || null,
    tokenSource,
    tokenConfigured: configuredToken.configured,
    reactionNotifications: effective.reactionNotifications ?? "own",
    reactionAllowlist: effective.reactionAllowlist,
    config: effective,
  }
}

export function inspectInlineAccount(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  env?: NodeJS.ProcessEnv
}): InspectedInlineAccount {
  const account = resolveInlineAccount(params)
  const inlineToken = account.token?.trim() ?? ""
  if (inlineToken) {
    return {
      ...account,
      token: inlineToken,
      tokenStatus: "available",
      configured: true,
    }
  }

  const tokenFile = account.tokenFile?.trim() ?? ""
  if (tokenFile) {
    const token = tryReadInlineTokenFile(tokenFile)
    return {
      ...account,
      token: token || null,
      tokenSource: "file",
      tokenStatus: token ? "available" : "configured_unavailable",
      configured: Boolean(token),
    }
  }

  return {
    ...account,
    tokenStatus: account.tokenConfigured ? "configured_unavailable" : "missing",
    configured: false,
  }
}

function orderedInlineAccountIds(cfg: OpenClawConfig, env?: NodeJS.ProcessEnv): string[] {
  const ids = listInlineAccountIds(cfg, env)
  if (!ids.includes(DEFAULT_ACCOUNT_ID)) {
    return ids
  }
  return [DEFAULT_ACCOUNT_ID, ...ids.filter((id) => id !== DEFAULT_ACCOUNT_ID)]
}

export function findInlineTokenOwnerAccountId(params: {
  cfg: OpenClawConfig
  accountId: string
  env?: NodeJS.ProcessEnv
}): string | null {
  const targetAccountId = normalizeInlineAccountId(params.accountId)
  const tokenOwners = new Map<string, string>()
  for (const id of orderedInlineAccountIds(params.cfg, params.env)) {
    const account = inspectInlineAccount({
      cfg: params.cfg,
      accountId: id,
      ...(params.env ? { env: params.env } : {}),
    })
    const token = account.token?.trim()
    if (!token) {
      continue
    }
    const ownerAccountId = tokenOwners.get(token)
    if (!ownerAccountId) {
      tokenOwners.set(token, account.accountId)
      continue
    }
    if (account.accountId === targetAccountId) {
      return ownerAccountId
    }
  }
  return null
}

export function formatDuplicateInlineTokenReason(params: {
  accountId: string
  ownerAccountId: string
}): string {
  return (
    `Duplicate Inline bot token: account "${params.accountId}" shares a token with ` +
    `account "${params.ownerAccountId}". Keep one owner account per Inline bot token.`
  )
}

export async function resolveInlineToken(account: ResolvedInlineAccount): Promise<string> {
  const inlineToken = (account.token ?? "").trim()
  if (inlineToken) return inlineToken

  const tokenFile = (account.tokenFile ?? "").trim()
  if (!tokenFile) {
    if (account.tokenConfigured) {
      throw new Error(
        "Inline token is configured but unavailable (resolve the token SecretRef before starting the Inline channel)",
      )
    }
    throw new Error(
      "Inline token missing (set channels.inline.token, channels.inline.tokenFile, INLINE_TOKEN, or INLINE_BOT_TOKEN)",
    )
  }

  const token = readInlineTokenFile(tokenFile)
  if (!token) throw new Error(`Inline tokenFile is empty or unreadable: ${tokenFile}`)
  return token
}

function tryReadInlineTokenFile(tokenFile: string): string {
  try {
    return tryReadSecretFileSync(tokenFile, "Inline bot token", {
      rejectSymlink: true,
    }) ?? ""
  } catch {
    return ""
  }
}

function readInlineTokenFile(tokenFile: string): string {
  try {
    return tryReadSecretFileSync(tokenFile, "Inline bot token", {
      rejectSymlink: true,
    }) ?? ""
  } catch (error) {
    throw new Error(`Inline tokenFile is empty or unreadable: ${tokenFile}`, {
      cause: error,
    })
  }
}
