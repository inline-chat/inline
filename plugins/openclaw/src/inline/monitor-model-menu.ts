import {
  buildCommandTextFromArgs,
  findCommandByNativeName,
  formatCommandArgMenuTitle,
  parseCommandArgs,
  resolveCommandArgMenuAsync,
} from "openclaw/plugin-sdk/native-command-registry"
import { resolveStoredModelOverrideAsync } from "openclaw/plugin-sdk/command-auth-native"
import {
  buildConfiguredModelCatalog,
  resolveAgentConfig,
  resolveDefaultModelForAgent,
  resolveThinkingDefault,
} from "openclaw/plugin-sdk/agent-runtime"
import {
  getSessionEntryAsync,
  type SessionEntry,
  resolveStorePath,
} from "openclaw/plugin-sdk/session-store-runtime"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { InlineReplyMarkupButton } from "./command-ui.js"
import { normalizeOptionalString } from "./monitor-shared.js"
import {
  findInlineNativeCommandFromBody,
  buildInlineNativeCommandCallbackData,
} from "./monitor-addressing.js"

type InlineModelPickerCallback =
  | { type: "providers" | "back" }
  | { type: "list"; provider: string; page: number }
  | { type: "select"; provider?: string; model: string }

type InlineModelPickerSelection =
  | { kind: "resolved"; provider: string; model: string }
  | { kind: "ambiguous"; model: string }

export function resolveInlineParentSessionKeyCandidate(
  sessionKey: string,
  entry: { parentSessionKey?: string } | undefined,
): string | undefined {
  const explicit = normalizeOptionalString(entry?.parentSessionKey)
  if (explicit && explicit !== sessionKey) return explicit

  const inlineThreadMarker = ":thread:"
  const markerIndex = sessionKey.lastIndexOf(inlineThreadMarker)
  if (markerIndex > 0) return sessionKey.slice(0, markerIndex)

  return undefined
}

type InlineSessionModelEntry = SessionEntry & {
  fallbackNoticeSelectedModel?: string
  fallbackNoticeActiveModel?: string
}

type InlineProviderModelRef = {
  provider: string
  model: string
}

function resolveInlineProviderModelRef(
  providerValue: unknown,
  modelValue: unknown,
): InlineProviderModelRef | undefined {
  let provider = normalizeOptionalString(providerValue)
  let model = normalizeOptionalString(modelValue)
  if (!model) return undefined

  const slash = model.indexOf("/")
  if (!provider && slash > 0 && slash < model.length - 1) {
    provider = model.slice(0, slash)
    model = model.slice(slash + 1)
  } else if (provider && model.startsWith(`${provider}/`)) {
    model = model.slice(provider.length + 1)
  }

  return provider && model ? { provider, model } : undefined
}

function resolveInlineFallbackModelContext(params: {
  entry?: InlineSessionModelEntry
  parentEntry?: InlineSessionModelEntry
  defaultModel: InlineProviderModelRef
  storedOverride?: InlineProviderModelRef | null
}): {
  selected: InlineProviderModelRef
  activeFallback?: InlineProviderModelRef
} {
  const entryHasOverride = Boolean(
    normalizeOptionalString(params.entry?.providerOverride) ||
    normalizeOptionalString(params.entry?.modelOverride),
  )
  const parentHasOverride = Boolean(
    normalizeOptionalString(params.parentEntry?.providerOverride) ||
    normalizeOptionalString(params.parentEntry?.modelOverride),
  )
  const overrideEntry = entryHasOverride
    ? params.entry
    : parentHasOverride
    ? params.parentEntry
    : undefined
  const fallbackEntry = overrideEntry?.modelOverrideSource === "auto" ||
      (normalizeOptionalString(overrideEntry?.modelOverrideFallbackOriginProvider) &&
        normalizeOptionalString(overrideEntry?.modelOverrideFallbackOriginModel))
    ? overrideEntry
    : undefined

  const selected = fallbackEntry
    ? resolveInlineProviderModelRef(
        fallbackEntry.modelOverrideFallbackOriginProvider,
        fallbackEntry.modelOverrideFallbackOriginModel,
      ) ?? resolveInlineProviderModelRef(undefined, fallbackEntry.fallbackNoticeSelectedModel)
        ?? params.defaultModel
    : params.storedOverride ?? params.defaultModel
  if (!fallbackEntry) return { selected }

  const activeFallback = resolveInlineProviderModelRef(
    params.entry?.modelProvider,
    params.entry?.model,
  ) ?? resolveInlineProviderModelRef(
    fallbackEntry.providerOverride,
    fallbackEntry.modelOverride,
  ) ?? resolveInlineProviderModelRef(undefined, fallbackEntry.fallbackNoticeActiveModel)
  if (
    !activeFallback ||
    (activeFallback.provider === selected.provider && activeFallback.model === selected.model)
  ) {
    return { selected }
  }
  return { selected, activeFallback }
}

export async function resolveInlineCommandMenuModelContext(params: {
  cfg: OpenClawConfig
  agentId: string
  sessionKey: string
}): Promise<{
  provider?: string
  model?: string
  activeProvider?: string
  activeModel?: string
  thinkingLevel?: string
}> {
  if (!params.sessionKey.trim()) {
    return {}
  }
  try {
    const storePath = resolveStorePath(params.cfg.session?.store, { agentId: params.agentId })
    const defaultModel = resolveDefaultModelForAgent({
      cfg: params.cfg,
      agentId: params.agentId,
    })
    const entry = await getSessionEntryAsync({
      agentId: params.agentId,
      sessionKey: params.sessionKey,
      storePath,
      readConsistency: "latest",
    }) as InlineSessionModelEntry | undefined
    const thinkingLevel = normalizeOptionalString(entry?.thinkingLevel)
    const parentSessionKey = resolveInlineParentSessionKeyCandidate(params.sessionKey, entry)
    const parentEntry = parentSessionKey
      ? await getSessionEntryAsync({
          agentId: params.agentId,
          sessionKey: parentSessionKey,
          storePath,
          readConsistency: "latest",
        }) as InlineSessionModelEntry | undefined
      : undefined
    const override = await resolveStoredModelOverrideAsync({
      ...(entry ? { sessionEntry: entry } : {}),
      ...(parentSessionKey ? { parentSessionKey } : {}),
      ...(parentSessionKey && parentEntry ? { sessionStore: { [parentSessionKey]: parentEntry } } : {}),
      sessionKey: params.sessionKey,
      defaultProvider: defaultModel.provider,
    })
    const modelContext = resolveInlineFallbackModelContext({
      ...(entry ? { entry } : {}),
      ...(parentEntry ? { parentEntry } : {}),
      defaultModel,
      ...(override?.model
        ? {
            storedOverride: {
              provider: override.provider || defaultModel.provider,
              model: override.model,
            },
          }
        : {}),
    })
    return {
      provider: modelContext.selected.provider,
      model: modelContext.selected.model,
      ...(modelContext.activeFallback
        ? {
            activeProvider: modelContext.activeFallback.provider,
            activeModel: modelContext.activeFallback.model,
          }
        : {}),
      ...(thinkingLevel ? { thinkingLevel } : {}),
    }
  } catch {
    return {}
  }
}

export function resolveInlineThinkMenuCurrentLevel(params: {
  cfg: OpenClawConfig
  agentId: string
  provider?: string
  model?: string
  thinkingLevel?: string
}): string {
  const explicit = normalizeOptionalString(params.thinkingLevel)
  if (explicit) return explicit

  const agentThinkingDefault = normalizeOptionalString(
    resolveAgentConfig(params.cfg, params.agentId)?.thinkingDefault,
  )
  if (agentThinkingDefault) return agentThinkingDefault

  const defaultModel = resolveDefaultModelForAgent({
    cfg: params.cfg,
    agentId: params.agentId,
  })
  return resolveThinkingDefault({
    cfg: params.cfg,
    provider: params.provider ?? defaultModel.provider,
    model: params.model ?? defaultModel.model,
    catalog: buildConfiguredModelCatalog({ cfg: params.cfg }),
  })
}

function formatInlineCommandArgMenuTitle(params: {
  command: NonNullable<ReturnType<typeof findCommandByNativeName>>
  menu: NonNullable<Awaited<ReturnType<typeof resolveCommandArgMenuAsync>>>
  currentThinkingLevel?: string
}): string {
  const title = formatCommandArgMenuTitle({ command: params.command, menu: params.menu })
  if (params.command.key !== "think" || !params.currentThinkingLevel) {
    return title
  }
  return `Current thinking level: ${params.currentThinkingLevel}.\n${title}`
}

export async function resolveInlineNativeCommandMenu(params: {
  commandBody: string
  cfg: OpenClawConfig
  agentId: string
  sessionKey: string
}): Promise<{
  title: string
  buttons: InlineReplyMarkupButton[][]
} | null> {
  const normalized = params.commandBody.trim()
  const match = normalized.match(/^\/([^\s]+)(?:\s+([\s\S]+))?$/)
  if (!match?.[1]) return null

  const command = findInlineNativeCommandFromBody(normalized)
  if (!command) return null

  const args = parseCommandArgs(command, match[2])
  const menuNeedsModelContext =
    command.argsMenu &&
    !(args?.raw && !args.values) &&
    command.args?.some(
      (arg) => typeof arg.choices === "function" && args?.values?.[arg.name] == null,
    )
  const menuModelContext = menuNeedsModelContext
    ? await resolveInlineCommandMenuModelContext({
        cfg: params.cfg,
        agentId: params.agentId,
        sessionKey: params.sessionKey,
      })
    : {}
  const menu = await resolveCommandArgMenuAsync({
    command,
    ...(args ? { args } : {}),
    cfg: params.cfg,
    ...menuModelContext,
  })
  if (!menu) return null

  const currentThinkingLevel =
    command.key === "think"
      ? resolveInlineThinkMenuCurrentLevel({
          cfg: params.cfg,
          agentId: params.agentId,
          ...menuModelContext,
        })
      : undefined
  const title = formatInlineCommandArgMenuTitle({
    command,
    menu,
    ...(currentThinkingLevel ? { currentThinkingLevel } : {}),
  })
  const rows: InlineReplyMarkupButton[][] = []
  for (let index = 0; index < menu.choices.length; index += 2) {
    const slice = menu.choices.slice(index, index + 2)
    rows.push(
      slice.map((choice) => ({
        text: choice.label,
        callback_data: buildInlineNativeCommandCallbackData(
          buildCommandTextFromArgs(command, {
            values: { [menu.arg.name]: choice.value },
          }),
        ),
      })),
    )
  }

  return { title, buttons: rows }
}

export function mapInlineModelPickerCallbackToCommand(raw: string): string | undefined {
  const callback = parseInlineModelPickerCallback(raw)
  if (!callback) return undefined
  switch (callback.type) {
    case "providers":
    case "back":
      return "/models"
    case "list":
      return `/models ${callback.provider} ${String(callback.page)}`
    case "select":
      return callback.provider ? `/model ${callback.provider}/${callback.model}` : `/model ${callback.model}`
  }
}

export function parseInlineModelPickerCallback(raw: string): InlineModelPickerCallback | null {
  const trimmed = raw.trim()
  if (!trimmed) return null

  if (trimmed === "mdl_prov") return { type: "providers" }
  if (trimmed === "mdl_back") return { type: "back" }

  const listMatch = trimmed.match(/^mdl_list_([a-z0-9_.-]+)_(\d+)$/i)
  if (listMatch?.[1] && listMatch[2]) {
    const provider = listMatch[1].trim()
    const page = Number.parseInt(listMatch[2], 10)
    if (provider && Number.isFinite(page) && page > 0) {
      return { type: "list", provider, page }
    }
  }

  const standardSelectionMatch = trimmed.match(/^mdl_sel_(.+)$/)
  if (standardSelectionMatch?.[1]?.trim()) {
    const modelRef = standardSelectionMatch[1].trim()
    const slashIndex = modelRef.indexOf("/")
    if (slashIndex > 0 && slashIndex < modelRef.length - 1) {
      return {
        type: "select",
        provider: modelRef.slice(0, slashIndex),
        model: modelRef.slice(slashIndex + 1),
      }
    }
  }

  const compactSelectionMatch = trimmed.match(/^mdl_sel\/(.+)$/)
  if (compactSelectionMatch?.[1]?.trim()) {
    return { type: "select", model: compactSelectionMatch[1].trim() }
  }

  return null
}

export function resolveInlineModelPickerSelection(params: {
  callback: Extract<InlineModelPickerCallback, { type: "select" }>
  providers: readonly string[]
  byProvider: ReadonlyMap<string, ReadonlySet<string>>
}): InlineModelPickerSelection {
  if (params.callback.provider) {
    return {
      kind: "resolved",
      provider: params.callback.provider,
      model: params.callback.model,
    }
  }

  const matchingProviders = params.providers.filter((id) => params.byProvider.get(id)?.has(params.callback.model))
  if (matchingProviders.length === 1 && matchingProviders[0]) {
    return {
      kind: "resolved",
      provider: matchingProviders[0],
      model: params.callback.model,
    }
  }

  return {
    kind: "ambiguous",
    model: params.callback.model,
  }
}
