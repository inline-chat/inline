import { BotAgentsModel } from "@in/server/db/models/botAgents"
import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { UsersModel } from "@in/server/db/models/users"
import type { DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { agentSessions } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
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

export function normalizeAgentThreadContext(context: AgentThreadContext): AgentThreadContext {
  const botUserId = Number(context.botUserId)
  const agentId = context.agentId === undefined ? undefined : Number(context.agentId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  if (agentId !== undefined && (!Number.isSafeInteger(agentId) || agentId <= 0)) {
    throw RealtimeRpcError.BadRequest()
  }

  const projectId = boundedOptional(context.configuration?.projectId, MAX_ID_BYTES)
  const modelId = boundedOptional(context.configuration?.modelId, MAX_ID_BYTES)
  const reasoningEffortId = boundedOptional(context.configuration?.reasoningEffortId, MAX_ID_BYTES)

  return {
    botUserId: BigInt(botUserId),
    agentId: agentId === undefined ? undefined : BigInt(agentId),
    configuration: projectId || modelId || reasoningEffortId
      ? { projectId, modelId, reasoningEffortId }
      : undefined,
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
  bindingActorUserId?: number,
): Promise<AgentThreadContext> {
  const normalized = normalizeAgentThreadContext(context)
  const botUserId = Number(normalized.botUserId)
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot)) throw RealtimeRpcError.UserIdInvalid()
  if (bindingActorUserId !== undefined) {
    const actor = bindingActorUserId === botUserId
      ? bot
      : await UsersModel.getUserById(bindingActorUserId)
    if (!actor || (!actor.bot && bot.botCreatorId !== bindingActorUserId)) {
      throw RealtimeRpcError.UserIdInvalid()
    }
  }

  if (normalized.agentId !== undefined) {
    const agent = await BotAgentsModel.get(Number(normalized.agentId))
    if (!agent || Number(agent.botUserId) !== botUserId) throw RealtimeRpcError.BadRequest()
  }

  const configuration = normalized.configuration
  if (!configuration) return normalized

  const capability = (await BotCapabilitiesModel.getForBotUserId(botUserId)).find(
    (item) => item.kind === AGENT_CONFIGURATION_CAPABILITY_KIND && item.version === AGENT_CONFIGURATION_VERSION,
  )
  const catalog = decodeAgentConfigurationCatalog(capability?.payload ?? null)
  if (!catalog) throw RealtimeRpcError.BadRequest()

  const projectIds = new Set(catalog.projects?.options.map((option) => option.id) ?? [])
  const model = catalog.models?.options.find((option) => option.id === configuration.modelId)
  const reasoningIds = new Set(catalog.reasoning?.options.map((option) => option.id) ?? [])
  if (configuration.projectId && !projectIds.has(configuration.projectId)) throw RealtimeRpcError.BadRequest()
  if (configuration.modelId && !model) throw RealtimeRpcError.BadRequest()
  if (configuration.reasoningEffortId && catalog.models && !model) {
    throw RealtimeRpcError.BadRequest()
  }
  if (configuration.reasoningEffortId && !reasoningIds.has(configuration.reasoningEffortId)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (
    configuration.reasoningEffortId &&
    model &&
    model.reasoningEffortIds.length > 0 &&
    !model.reasoningEffortIds.includes(configuration.reasoningEffortId)
  ) {
    throw RealtimeRpcError.BadRequest()
  }
  return normalized
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
