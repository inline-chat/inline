import { BotAgentsModel } from "@in/server/db/models/botAgents"
import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { UsersModel } from "@in/server/db/models/users"
import type { DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { agentSessions } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import {
  AgentConfigurationCatalog,
  AgentThreadContext,
  type AgentModelOption,
  type AgentProjectOption,
  type AgentReasoningEffortOption,
} from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"

export const AGENT_CONFIGURATION_VERSION = 1
export const AGENT_CONFIGURATION_CAPABILITY_KIND = "agent_configuration"

const MAX_CATALOG_OPTIONS = 500
const MAX_REASONING_OPTIONS = 64
const MAX_ID_BYTES = 256
const MAX_LABEL_BYTES = 256
const MAX_DESCRIPTION_BYTES = 2_000
const MAX_CATALOG_BYTES = 512 * 1_024

const log = new Log("modules.agentConfiguration")

export type AgentContextSanitizationReason =
  | "invalid_agent_id"
  | "agent_unavailable"
  | "invalid_project"
  | "invalid_model"
  | "invalid_reasoning"
  | "configuration_unavailable"
  | "project_unavailable"
  | "model_unavailable"
  | "model_required"
  | "reasoning_unavailable"
  | "reasoning_unsupported"

export type AgentContextValidationOperation =
  | "create_chat"
  | "create_subthread"
  | "initial_message"
  | "update_chat_info"

type AgentContextValidationOptions = {
  operation: AgentContextValidationOperation
  bindingActorUserId?: number
}

const utf8Bytes = (value: string): number => Buffer.byteLength(value, "utf8")

const boundedRequired = (value: string, maxBytes: number): string => {
  const normalized = value.trim()
  if (!normalized || utf8Bytes(normalized) > maxBytes) throw RealtimeRpcError.BadRequest()
  return normalized
}

const boundedOptional = (value: string | undefined, maxBytes: number): string | undefined => {
  if (value === undefined) return undefined
  const normalized = value.trim()
  if (!normalized || utf8Bytes(normalized) > maxBytes) throw RealtimeRpcError.BadRequest()
  return normalized
}

const sanitizedAgentSelection = (
  value: string | undefined,
  reason: AgentContextSanitizationReason,
  discarded: AgentContextSanitizationReason[],
): string | undefined => {
  if (value === undefined) return undefined
  const normalized = value.trim()
  if (!normalized || utf8Bytes(normalized) > MAX_ID_BYTES) {
    discarded.push(reason)
    return undefined
  }
  return normalized
}

const normalizeProject = (option: AgentProjectOption): AgentProjectOption => ({
  id: boundedRequired(option.id, MAX_ID_BYTES),
  label: boundedRequired(option.label, MAX_LABEL_BYTES),
  description: boundedOptional(option.description, MAX_DESCRIPTION_BYTES),
})

const normalizeReasoning = (option: AgentReasoningEffortOption): AgentReasoningEffortOption => ({
  id: boundedRequired(option.id, MAX_ID_BYTES),
  label: boundedRequired(option.label, MAX_LABEL_BYTES),
  description: boundedOptional(option.description, MAX_DESCRIPTION_BYTES),
})

const normalizeModel = (option: AgentModelOption): AgentModelOption => ({
  id: boundedRequired(option.id, MAX_ID_BYTES),
  label: boundedRequired(option.label, MAX_LABEL_BYTES),
  description: boundedOptional(option.description, MAX_DESCRIPTION_BYTES),
  reasoningEffortIds: option.reasoningEffortIds.map((id) => boundedRequired(id, MAX_ID_BYTES)),
  defaultReasoningEffortId: boundedOptional(option.defaultReasoningEffortId, MAX_ID_BYTES),
})

const assertUniqueIds = (ids: string[]): void => {
  if (new Set(ids).size !== ids.length) throw RealtimeRpcError.BadRequest()
}

export function normalizeAgentConfigurationCatalog(
  catalog: AgentConfigurationCatalog,
): AgentConfigurationCatalog {
  if (
    (catalog.projects?.options.length ?? 0) > MAX_CATALOG_OPTIONS ||
    (catalog.models?.options.length ?? 0) > MAX_CATALOG_OPTIONS ||
    (catalog.reasoning?.options.length ?? 0) > MAX_REASONING_OPTIONS
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const projects = catalog.projects
    ? {
        options: catalog.projects.options.map(normalizeProject),
        canSelectFolder: catalog.projects.canSelectFolder,
        defaultProjectId: boundedOptional(catalog.projects.defaultProjectId, MAX_ID_BYTES),
      }
    : undefined
  const reasoning = catalog.reasoning
    ? { options: catalog.reasoning.options.map(normalizeReasoning) }
    : undefined
  const models = catalog.models
    ? {
        options: catalog.models.options.map(normalizeModel),
        defaultModelId: boundedOptional(catalog.models.defaultModelId, MAX_ID_BYTES),
      }
    : undefined

  assertUniqueIds(projects?.options.map((option) => option.id) ?? [])
  assertUniqueIds(models?.options.map((option) => option.id) ?? [])
  assertUniqueIds(reasoning?.options.map((option) => option.id) ?? [])

  const reasoningIds = new Set(reasoning?.options.map((option) => option.id) ?? [])
  const projectIds = new Set(projects?.options.map((option) => option.id) ?? [])
  const modelIds = new Set(models?.options.map((option) => option.id) ?? [])
  if (projects?.defaultProjectId && !projectIds.has(projects.defaultProjectId)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (models?.defaultModelId && !modelIds.has(models.defaultModelId)) {
    throw RealtimeRpcError.BadRequest()
  }
  for (const model of models?.options ?? []) {
    assertUniqueIds(model.reasoningEffortIds)
    if (model.reasoningEffortIds.some((id) => !reasoningIds.has(id))) {
      throw RealtimeRpcError.BadRequest()
    }
    if (
      model.defaultReasoningEffortId &&
      (
        !reasoningIds.has(model.defaultReasoningEffortId) ||
        (model.reasoningEffortIds.length > 0 && !model.reasoningEffortIds.includes(model.defaultReasoningEffortId))
      )
    ) {
      throw RealtimeRpcError.BadRequest()
    }
  }

  const normalized = { projects, models, reasoning }
  if (AgentConfigurationCatalog.toBinary(normalized).byteLength > MAX_CATALOG_BYTES) {
    throw RealtimeRpcError.BadRequest()
  }
  return normalized
}

export const encodeAgentConfigurationCatalog = (catalog: AgentConfigurationCatalog): Buffer =>
  Buffer.from(AgentConfigurationCatalog.toBinary(catalog))

export function decodeAgentConfigurationCatalog(bytes: Uint8Array | null): AgentConfigurationCatalog | undefined {
  if (!bytes) return undefined
  try {
    return AgentConfigurationCatalog.fromBinary(bytes)
  } catch {
    return undefined
  }
}

type AgentThreadContextSanitization = {
  context: AgentThreadContext
  discarded: AgentContextSanitizationReason[]
}

const sanitizeAgentThreadContextShape = (context: AgentThreadContext): AgentThreadContextSanitization => {
  const botUserId = Number(context.botUserId)
  const agentId = context.agentId === undefined ? undefined : Number(context.agentId)
  const discarded: AgentContextSanitizationReason[] = []
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const sanitizedAgentId = agentId !== undefined && (!Number.isSafeInteger(agentId) || agentId <= 0)
    ? undefined
    : agentId
  if (agentId !== undefined && sanitizedAgentId === undefined) discarded.push("invalid_agent_id")

  const projectId = sanitizedAgentSelection(context.configuration?.projectId, "invalid_project", discarded)
  const modelId = sanitizedAgentSelection(context.configuration?.modelId, "invalid_model", discarded)
  const reasoningEffortId = sanitizedAgentSelection(
    context.configuration?.reasoningEffortId,
    "invalid_reasoning",
    discarded,
  )

  return {
    context: {
      botUserId: BigInt(botUserId),
      agentId: sanitizedAgentId === undefined ? undefined : BigInt(sanitizedAgentId),
      configuration: projectId || modelId || reasoningEffortId
        ? { projectId, modelId, reasoningEffortId }
        : undefined,
    },
    discarded,
  }
}

export function normalizeAgentThreadContext(context: AgentThreadContext): AgentThreadContext {
  return sanitizeAgentThreadContextShape(context).context
}

export const agentContextSanitizationMetadata = (
  operation: AgentContextValidationOperation,
  input: AgentThreadContext,
  sanitized: AgentThreadContext,
  discarded: readonly AgentContextSanitizationReason[],
): Record<string, string | number | boolean> => {
  const hadAgentId = input.agentId !== undefined
  const hadProject = input.configuration?.projectId !== undefined
  const hadModel = input.configuration?.modelId !== undefined
  const hadReasoning = input.configuration?.reasoningEffortId !== undefined
  const keptAgentId = sanitized.agentId !== undefined
  const keptProject = sanitized.configuration?.projectId !== undefined
  const keptModel = sanitized.configuration?.modelId !== undefined
  const keptReasoning = sanitized.configuration?.reasoningEffortId !== undefined
  const discardedItemCount = [
    hadAgentId && !keptAgentId,
    hadProject && !keptProject,
    hadModel && !keptModel,
    hadReasoning && !keptReasoning,
  ].filter(Boolean).length

  return {
    event: "agent_context.sanitized",
    operation,
    reasonCodes: Array.from(new Set(discarded)).sort().join(","),
    reasonCount: discarded.length,
    discardedItemCount,
    hadAgentId,
    hadConfiguration: input.configuration !== undefined,
    hadProject,
    hadModel,
    hadReasoning,
    keptAgentId,
    keptConfiguration: sanitized.configuration !== undefined,
    keptProject,
    keptModel,
    keptReasoning,
  }
}

export const encodeAgentThreadContext = (context: AgentThreadContext): Buffer =>
  Buffer.from(AgentThreadContext.toBinary(context))

export function decodeAgentThreadContext(bytes: Uint8Array | null): AgentThreadContext | undefined {
  if (!bytes) return undefined
  try {
    return AgentThreadContext.fromBinary(bytes)
  } catch {
    return undefined
  }
}

export async function validateAgentThreadContext(
  context: AgentThreadContext,
  options: AgentContextValidationOptions,
): Promise<AgentThreadContext> {
  const normalizedShape = sanitizeAgentThreadContextShape(context)
  const normalized = normalizedShape.context
  const discarded = normalizedShape.discarded
  const botUserId = Number(normalized.botUserId)
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot)) throw RealtimeRpcError.UserIdInvalid()
  if (options.bindingActorUserId !== undefined) {
    const actor = options.bindingActorUserId === botUserId
      ? bot
      : await UsersModel.getUserById(options.bindingActorUserId)
    if (!actor || (!actor.bot && bot.botCreatorId !== options.bindingActorUserId)) {
      throw RealtimeRpcError.UserIdInvalid()
    }
  }

  let agentId = normalized.agentId
  if (agentId !== undefined) {
    const agent = await BotAgentsModel.get(Number(agentId))
    if (!agent || Number(agent.botUserId) !== botUserId) {
      agentId = undefined
      discarded.push("agent_unavailable")
    }
  }

  let configuration = normalized.configuration
  if (configuration) {
    const capability = (await BotCapabilitiesModel.getForBotUserId(botUserId)).find(
      (item) => item.kind === AGENT_CONFIGURATION_CAPABILITY_KIND && item.version === AGENT_CONFIGURATION_VERSION,
    )
    const catalog = decodeAgentConfigurationCatalog(capability?.payload ?? null)
    if (!catalog) {
      configuration = undefined
      discarded.push("configuration_unavailable")
    } else {
      const projectIds = new Set(catalog.projects?.options.map((option) => option.id) ?? [])
      const reasoningIds = new Set(catalog.reasoning?.options.map((option) => option.id) ?? [])
      let projectId = configuration.projectId
      let modelId = configuration.modelId
      let reasoningEffortId = configuration.reasoningEffortId

      if (projectId && !projectIds.has(projectId)) {
        projectId = undefined
        discarded.push("project_unavailable")
      }

      const selectedModel = catalog.models?.options.find((option) => option.id === modelId)
      if (modelId && !selectedModel) {
        modelId = undefined
        discarded.push("model_unavailable")
      }

      const effectiveModelId = modelId ?? catalog.models?.defaultModelId
      const effectiveModel = catalog.models?.options.find((option) => option.id === effectiveModelId)

      if (reasoningEffortId && catalog.models && !effectiveModel) {
        reasoningEffortId = undefined
        discarded.push("model_required")
      } else if (reasoningEffortId && !reasoningIds.has(reasoningEffortId)) {
        reasoningEffortId = undefined
        discarded.push("reasoning_unavailable")
      } else if (
        reasoningEffortId &&
        effectiveModel &&
        effectiveModel.reasoningEffortIds.length > 0 &&
        !effectiveModel.reasoningEffortIds.includes(reasoningEffortId)
      ) {
        reasoningEffortId = undefined
        discarded.push("reasoning_unsupported")
      }

      configuration = projectId || modelId || reasoningEffortId
        ? { projectId, modelId, reasoningEffortId }
        : undefined
    }
  }

  const sanitized = { botUserId: normalized.botUserId, agentId, configuration }
  if (discarded.length > 0) {
    log.warn(
      "Agent context sanitized",
      agentContextSanitizationMetadata(options.operation, context, sanitized, discarded),
    )
  }
  return sanitized
}

export async function hasProviderSession(
  chatId: number,
  query: Pick<typeof db, "select"> | Pick<Transaction, "select"> = db,
): Promise<boolean> {
  const [row] = await query
    .select({ id: agentSessions.id })
    .from(agentSessions)
    .where(eq(agentSessions.chatId, chatId))
    .limit(1)
  return row !== undefined
}

export function chatAgentContext(chat: Pick<DbChat, "agentContext">): AgentThreadContext | undefined {
  if (chat.agentContext === null) return undefined
  const context = decodeAgentThreadContext(chat.agentContext)
  if (!context) throw RealtimeRpcError.InternalError()
  return context
}
