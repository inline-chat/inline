import {
  BotChatSettingsInfo_Tone,
  BotChatSettingsProblem_Code,
  type BotChatSettingsDocument,
  type BotChatSettingsResponse,
  type BotChatSettingsValue,
} from "@inline-chat/realtime-sdk"

export const OPENCLAW_BOT_CHAT_SETTINGS_VERSION = 1

const MODEL_ITEM_ID = "model"
const DEFAULT_MODEL_ITEM_ID = "model-default"
const REASONING_ITEM_ID = "reasoning"
const FOLLOWING_ITEM_ID = "following"
const REPLY_THREADS_ITEM_ID = "reply-threads"
const READ_ONLY_REASON = "Only an authorized OpenClaw controller can change this."

export type OpenClawBotChatSettingsOption = {
  value: string
  label: string
  description?: string
  disabled?: boolean
}

export type OpenClawBotChatSettingsContext = {
  scopeId: string
  access: "full" | "readOnly" | "guideOnly"
  isReplyThread?: boolean
  currentModel?: string
  activeModel?: string
  defaultModel?: string
  modelOptions?: OpenClawBotChatSettingsOption[]
  reasoningLevel?: string
  reasoningOptions?: OpenClawBotChatSettingsOption[]
  following?: boolean
  replyThreads: "auto" | "on" | "off"
  canSetDefaultModel?: boolean
}

export type OpenClawBotChatSettingsMutators = {
  setModel?(value: string): Promise<void>
  setDefaultModel?(): Promise<void>
  setReasoningLevel?(value: string): Promise<void>
  setFollowing?(value: boolean): Promise<void>
  setReplyThreads?(value: "auto" | "on" | "off"): Promise<void>
  resolveContext(): Promise<OpenClawBotChatSettingsContext>
}

function revisionFor(parts: string[]): string {
  let hash = 0x811c9dc5
  for (const byte of new TextEncoder().encode(parts.join("\u001f"))) {
    hash ^= byte
    hash = Math.imul(hash, 0x01000193)
  }
  return `openclaw-v1-${(hash >>> 0).toString(16).padStart(8, "0")}`
}

function responseWithDocument(document: BotChatSettingsDocument): BotChatSettingsResponse {
  return { result: { oneofKind: "document", document } }
}

export function openClawBotChatSettingsProblem(
  code: BotChatSettingsProblem_Code,
  message: string,
  currentDocument?: BotChatSettingsDocument,
): BotChatSettingsResponse {
  return {
    result: {
      oneofKind: "problem",
      problem: { code, message, ...(currentDocument ? { currentDocument } : {}) },
    },
  }
}

function disabledFields(context: OpenClawBotChatSettingsContext) {
  return context.access === "full"
    ? { disabled: false }
    : { disabled: true, disabledReason: READ_ONLY_REASON }
}

function optionsRevision(options: OpenClawBotChatSettingsOption[] | undefined): string[] {
  return (options ?? []).flatMap((option) => [
    option.value,
    option.label,
    option.description ?? "",
    String(option.disabled === true),
  ])
}

export function buildOpenClawBotChatSettingsDocument(
  context: OpenClawBotChatSettingsContext,
): BotChatSettingsDocument {
  if (context.access === "guideOnly") {
    return {
      version: OPENCLAW_BOT_CHAT_SETTINGS_VERSION,
      revision: revisionFor([context.scopeId, "guide-only"]),
      sections: [{
        id: "access",
        items: [{
          id: "access-guide",
          label: "OpenClaw unavailable",
          disabled: false,
          control: {
            oneofKind: "info",
            info: {
              text: "This chat is not allowed by OpenClaw's access policy.",
              tone: BotChatSettingsInfo_Tone.WARNING,
            },
          },
        }],
      }],
    }
  }

  const disabled = disabledFields(context)
  const modelOptions = context.modelOptions ?? []
  const reasoningOptions = context.reasoningOptions ?? []
  const runtimeItems: BotChatSettingsDocument["sections"][number]["items"] = []

  if (context.currentModel && modelOptions.length > 0) {
    const currentModelUnavailable = modelOptions.some(
      (option) => option.value === context.currentModel && option.disabled === true,
    )
    const modelDescription = context.activeModel && context.activeModel !== context.currentModel
      ? `This session. Using backup ${context.activeModel} after ${context.currentModel} failed.`
      : currentModelUnavailable
        ? "This session. The selected model is unavailable in OpenClaw."
        : "This session."
    runtimeItems.push({
      id: MODEL_ITEM_ID,
      label: "Model",
      description: modelDescription,
      ...disabled,
      control: {
        oneofKind: "select",
        select: {
          value: context.currentModel,
          options: modelOptions.map((option) => ({ ...option, disabled: option.disabled === true })),
        },
      },
    })
    if (
      context.canSetDefaultModel &&
      context.currentModel !== context.defaultModel
    ) {
      runtimeItems.push({
        id: DEFAULT_MODEL_ITEM_ID,
        label: "Use as default",
        description: "For new sessions.",
        ...disabled,
        control: { oneofKind: "button", button: {} },
      })
    }
  }

  if (context.reasoningLevel && reasoningOptions.length > 0) {
    runtimeItems.push({
      id: REASONING_ITEM_ID,
      label: "Reasoning",
      ...disabled,
      control: {
        oneofKind: "select",
        select: {
          value: context.reasoningLevel,
          options: reasoningOptions.map((option) => ({ ...option, disabled: false })),
        },
      },
    })
  }

  if (runtimeItems.length === 0) {
    runtimeItems.push({
      id: "runtime-unavailable",
      label: "Runtime",
      disabled: false,
      control: {
        oneofKind: "info",
        info: {
          text: "Runtime options are not available for this session.",
          tone: BotChatSettingsInfo_Tone.NEUTRAL,
        },
      },
    })
  }

  const sections: BotChatSettingsDocument["sections"] = [
    { id: "runtime", items: runtimeItems },
  ]

  if (context.following != null) {
    sections.push({
      id: "attention",
      items: [{
        id: FOLLOWING_ITEM_ID,
        label: "Following",
        description: "Wake on eligible activity.",
        ...disabled,
        control: { oneofKind: "toggle", toggle: { value: context.following } },
      }],
    })
  }

  sections.push({
    id: "replies",
    items: [{
      id: REPLY_THREADS_ITEM_ID,
      label: "Reply in threads",
      ...disabled,
      control: {
        oneofKind: "select",
        select: {
          value: context.replyThreads,
          options: [
            { value: "auto", label: "Auto", description: "Agent decides.", disabled: false },
            { value: "on", label: "On", description: "Always use threads.", disabled: false },
            { value: "off", label: "Off", description: "Stay in chat.", disabled: false },
          ],
        },
      },
    }],
  })

  if (context.access === "readOnly") {
    sections.push({
      id: "access",
      items: [{
        id: "read-only",
        label: "Read-only",
        disabled: false,
        control: {
          oneofKind: "info",
          info: {
            text: context.isReplyThread
              ? "Access and reply mode inherit from the parent chat. Model, reasoning, and following stay with this thread."
              : "An OpenClaw owner controls who can make changes.",
            tone: BotChatSettingsInfo_Tone.WARNING,
          },
        },
      }],
    })
  }

  return {
    version: OPENCLAW_BOT_CHAT_SETTINGS_VERSION,
    revision: revisionFor([
      context.scopeId,
      context.access,
      context.isReplyThread ? "reply" : "top",
      context.currentModel ?? "",
      context.activeModel ?? "",
      context.defaultModel ?? "",
      context.reasoningLevel ?? "",
      context.following == null ? "unknown" : String(context.following),
      context.replyThreads,
      String(context.canSetDefaultModel === true),
      ...optionsRevision(modelOptions),
      ...optionsRevision(reasoningOptions),
    ]),
    sections,
  }
}

function stringValue(value: BotChatSettingsValue | undefined): string | null {
  return value?.value.oneofKind === "stringValue" ? value.value.stringValue : null
}

function boolValue(value: BotChatSettingsValue | undefined): boolean | null {
  return value?.value.oneofKind === "boolValue" ? value.value.boolValue : null
}

export async function invokeOpenClawBotChatSetting(params: {
  context: OpenClawBotChatSettingsContext
  mutators: OpenClawBotChatSettingsMutators
  itemId: string
  value?: BotChatSettingsValue
  documentRevision: string
}): Promise<BotChatSettingsResponse> {
  const currentDocument = buildOpenClawBotChatSettingsDocument(params.context)
  if (params.documentRevision !== currentDocument.revision) {
    return openClawBotChatSettingsProblem(
      BotChatSettingsProblem_Code.STALE,
      "Settings changed. Try again.",
      currentDocument,
    )
  }
  if (params.context.access !== "full") {
    return openClawBotChatSettingsProblem(
      BotChatSettingsProblem_Code.FAILED,
      "You do not have access to change this.",
      currentDocument,
    )
  }

  const selected = stringValue(params.value)
  if (params.itemId === MODEL_ITEM_ID) {
    if (
      !selected ||
      !params.context.modelOptions?.some(
        (option) => option.value === selected && option.disabled !== true,
      ) ||
      !params.mutators.setModel
    ) {
      return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Model unavailable.", currentDocument)
    }
    await params.mutators.setModel(selected)
  } else if (params.itemId === DEFAULT_MODEL_ITEM_ID) {
    if (params.value != null || !params.context.canSetDefaultModel || !params.mutators.setDefaultModel) {
      return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Default model unavailable.", currentDocument)
    }
    await params.mutators.setDefaultModel()
  } else if (params.itemId === REASONING_ITEM_ID) {
    if (!selected || !params.context.reasoningOptions?.some((option) => option.value === selected) || !params.mutators.setReasoningLevel) {
      return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Reasoning level unavailable.", currentDocument)
    }
    await params.mutators.setReasoningLevel(selected)
  } else if (params.itemId === FOLLOWING_ITEM_ID) {
    const enabled = boolValue(params.value)
    if (enabled == null || params.context.following == null || !params.mutators.setFollowing) {
      return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Following unavailable.", currentDocument)
    }
    await params.mutators.setFollowing(enabled)
  } else if (params.itemId === REPLY_THREADS_ITEM_ID) {
    if ((selected !== "auto" && selected !== "on" && selected !== "off") || !params.mutators.setReplyThreads) {
      return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Reply mode unavailable.", currentDocument)
    }
    await params.mutators.setReplyThreads(selected)
  } else {
    return openClawBotChatSettingsProblem(BotChatSettingsProblem_Code.INVALID_VALUE, "Setting unavailable.", currentDocument)
  }

  return responseWithDocument(buildOpenClawBotChatSettingsDocument(await params.mutators.resolveContext()))
}
