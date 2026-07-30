import {
  BotChatSettingsInfo_Tone,
  BotChatSettingsProblem_Code,
  type BotChatSettingsDocument,
  type BotChatSettingsFolderOption,
  type BotChatSettingsItem,
  type BotChatSettingsResponse,
  type BotChatSettingsSection,
  type BotChatSettingsSelectOption,
  type BotChatSettingsValue,
} from "@inline-chat/protocol/core"
import { BOT_CHAT_SETTINGS_VERSION } from "@in/server/functions/bot.capabilitiesShared"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const BOT_CHAT_SETTINGS_LIMITS = {
  sections: 100,
  items: 100,
  selectOptions: 100,
  folderOptions: 8,
  id: 128,
  label: 256,
  description: 4_096,
  revision: 128,
  infoText: 8_192,
  textValue: 32_768,
  optionValue: 256,
  hostInstallationId: 128,
  localPickerCapability: 128,
  problemMessage: 1_024,
  documentBytes: 256 * 1_024,
} as const

export const invalidBotChatSettingsResponse = (): BotChatSettingsResponse => ({
  result: {
    oneofKind: "problem",
    problem: {
      code: BotChatSettingsProblem_Code.FAILED,
      message: "Bot returned invalid settings",
    },
  },
})

export const unreachableBotChatSettingsResponse = (): BotChatSettingsResponse => ({
  result: {
    oneofKind: "problem",
    problem: {
      code: BotChatSettingsProblem_Code.UNREACHABLE,
      message: "Bot unreachable",
    },
  },
})

const utf8Length = (value: string): number => Buffer.byteLength(value, "utf8")

function requiredString(value: string | undefined, maxLength: number): string {
  const normalized = value?.trim() ?? ""
  if (!normalized || utf8Length(normalized) > maxLength) throw RealtimeRpcError.BadRequest()
  return normalized
}

function optionalString(value: string | undefined, maxLength: number): string | undefined {
  if (value == null) return undefined
  const normalized = value.trim()
  if (!normalized) return undefined
  if (utf8Length(normalized) > maxLength) throw RealtimeRpcError.BadRequest()
  return normalized
}

function boundedText(value: string | undefined, maxLength: number): string {
  if (value == null || utf8Length(value) > maxLength) throw RealtimeRpcError.BadRequest()
  return value
}

function opaqueIdentifier(value: string | undefined, maxLength: number): string {
  const normalized = requiredString(value, maxLength)
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(normalized)) throw RealtimeRpcError.BadRequest()
  return normalized
}

function localLoopbackPort(value: number | undefined): number {
  if (value == null || !Number.isInteger(value) || value < 1024 || value > 65_535) {
    throw RealtimeRpcError.BadRequest()
  }
  return value
}

function displayComponent(value: string | undefined, maxLength: number, required: true): string
function displayComponent(value: string | undefined, maxLength: number, required: false): string | undefined
function displayComponent(value: string | undefined, maxLength: number, required: boolean): string | undefined {
  const normalized = required
    ? requiredString(value, maxLength)
    : optionalString(value, maxLength)
  if (normalized != null && (/[\\/]/.test(normalized) || /[\u0000-\u001f\u007f]/.test(normalized))) {
    throw RealtimeRpcError.BadRequest()
  }
  return normalized
}

function normalizeOption(option: BotChatSettingsSelectOption): BotChatSettingsSelectOption {
  return {
    value: requiredString(option.value, BOT_CHAT_SETTINGS_LIMITS.optionValue),
    label: requiredString(option.label, BOT_CHAT_SETTINGS_LIMITS.label),
    description: optionalString(option.description, BOT_CHAT_SETTINGS_LIMITS.description),
    disabled: option.disabled,
  }
}

function normalizeFolderOption(option: BotChatSettingsFolderOption): BotChatSettingsFolderOption {
  return {
    value: opaqueIdentifier(option.value, BOT_CHAT_SETTINGS_LIMITS.optionValue),
    label: displayComponent(option.label, BOT_CHAT_SETTINGS_LIMITS.label, true),
    parentHint: displayComponent(option.parentHint, BOT_CHAT_SETTINGS_LIMITS.label, false),
    disabled: option.disabled,
  }
}

function normalizeItem(item: BotChatSettingsItem): BotChatSettingsItem {
  const common = {
    id: requiredString(item.id, BOT_CHAT_SETTINGS_LIMITS.id),
    label: optionalString(item.label, BOT_CHAT_SETTINGS_LIMITS.label),
    description: optionalString(item.description, BOT_CHAT_SETTINGS_LIMITS.description),
    disabled: item.disabled,
    disabledReason: optionalString(item.disabledReason, BOT_CHAT_SETTINGS_LIMITS.description),
  }

  switch (item.control.oneofKind) {
    case "toggle":
      if (!common.label) throw RealtimeRpcError.BadRequest()
      return { ...common, control: { oneofKind: "toggle", toggle: { value: item.control.toggle.value } } }
    case "select": {
      if (!common.label || item.control.select.options.length === 0 ||
        item.control.select.options.length > BOT_CHAT_SETTINGS_LIMITS.selectOptions) {
        throw RealtimeRpcError.BadRequest()
      }
      const options = item.control.select.options.map(normalizeOption)
      if (new Set(options.map((option) => option.value)).size !== options.length) throw RealtimeRpcError.BadRequest()
      const value = requiredString(item.control.select.value, BOT_CHAT_SETTINGS_LIMITS.optionValue)
      if (!options.some((option) => option.value === value)) throw RealtimeRpcError.BadRequest()
      return { ...common, control: { oneofKind: "select", select: { value, options } } }
    }
    case "info": {
      const tone = item.control.info.tone
      if (!Object.values(BotChatSettingsInfo_Tone).includes(tone)) throw RealtimeRpcError.BadRequest()
      return {
        ...common,
        control: {
          oneofKind: "info",
          info: {
            text: boundedText(item.control.info.text, BOT_CHAT_SETTINGS_LIMITS.infoText),
            tone: tone === BotChatSettingsInfo_Tone.TONE_UNSPECIFIED ? BotChatSettingsInfo_Tone.NEUTRAL : tone,
          },
        },
      }
    }
    case "button":
      if (!common.label) throw RealtimeRpcError.BadRequest()
      return { ...common, control: { oneofKind: "button", button: {} } }
    case "folder": {
      if (!common.label || item.control.folder.recentFolders.length === 0 ||
        item.control.folder.recentFolders.length > BOT_CHAT_SETTINGS_LIMITS.folderOptions) {
        throw RealtimeRpcError.BadRequest()
      }
      const recentFolders = item.control.folder.recentFolders.map(normalizeFolderOption)
      if (new Set(recentFolders.map((option) => option.value)).size !== recentFolders.length) {
        throw RealtimeRpcError.BadRequest()
      }
      const value = opaqueIdentifier(item.control.folder.value, BOT_CHAT_SETTINGS_LIMITS.optionValue)
      if (!recentFolders.some((option) => option.value === value)) throw RealtimeRpcError.BadRequest()
      const pickerPort = item.control.folder.localPickerPort
      const pickerCapability = item.control.folder.localPickerCapability
      const hasPickerEndpoint = pickerPort != null || pickerCapability != null
      if (item.control.folder.allowsLocalPicker !== hasPickerEndpoint) throw RealtimeRpcError.BadRequest()
      const localPickerPort = hasPickerEndpoint ? localLoopbackPort(pickerPort) : undefined
      const localPickerCapability = hasPickerEndpoint
        ? opaqueIdentifier(pickerCapability, BOT_CHAT_SETTINGS_LIMITS.localPickerCapability)
        : undefined
      return {
        ...common,
        control: {
          oneofKind: "folder",
          folder: {
            value,
            recentFolders,
            hostInstallationId: opaqueIdentifier(
              item.control.folder.hostInstallationId,
              BOT_CHAT_SETTINGS_LIMITS.hostInstallationId,
            ),
            hostLabel: displayComponent(item.control.folder.hostLabel, BOT_CHAT_SETTINGS_LIMITS.label, true),
            allowsLocalPicker: item.control.folder.allowsLocalPicker,
            localPickerPort,
            localPickerCapability,
          },
        },
      }
    }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

function normalizeSection(section: BotChatSettingsSection): BotChatSettingsSection {
  return {
    id: requiredString(section.id, BOT_CHAT_SETTINGS_LIMITS.id),
    title: optionalString(section.title, BOT_CHAT_SETTINGS_LIMITS.label),
    description: optionalString(section.description, BOT_CHAT_SETTINGS_LIMITS.description),
    items: section.items.map(normalizeItem),
  }
}

export function normalizeBotChatSettingsDocument(document: BotChatSettingsDocument): BotChatSettingsDocument {
  if (document.version !== BOT_CHAT_SETTINGS_VERSION || document.sections.length > BOT_CHAT_SETTINGS_LIMITS.sections) {
    throw RealtimeRpcError.BadRequest()
  }
  const sections = document.sections.map(normalizeSection)
  if (new Set(sections.map((section) => section.id)).size !== sections.length) throw RealtimeRpcError.BadRequest()

  const itemIds = sections.flatMap((section) => section.items.map((item) => item.id))
  if (itemIds.length > BOT_CHAT_SETTINGS_LIMITS.items || new Set(itemIds).size !== itemIds.length) {
    throw RealtimeRpcError.BadRequest()
  }
  const normalized = {
    version: document.version,
    revision: requiredString(document.revision, BOT_CHAT_SETTINGS_LIMITS.revision),
    sections,
  }
  if (utf8Length(JSON.stringify(normalized)) > BOT_CHAT_SETTINGS_LIMITS.documentBytes) {
    throw RealtimeRpcError.BadRequest()
  }
  return normalized
}

export function normalizeBotChatSettingsResponse(
  response: BotChatSettingsResponse | undefined,
): BotChatSettingsResponse {
  switch (response?.result.oneofKind) {
    case "document":
      return {
        result: {
          oneofKind: "document",
          document: normalizeBotChatSettingsDocument(response.result.document),
        },
      }
    case "problem": {
      const { code } = response.result.problem
      if (
        code === BotChatSettingsProblem_Code.CODE_UNSPECIFIED ||
        code === BotChatSettingsProblem_Code.UNREACHABLE ||
        !Object.values(BotChatSettingsProblem_Code).includes(code)
      ) {
        throw RealtimeRpcError.BadRequest()
      }
      const currentDocument = response.result.problem.currentDocument
        ? normalizeBotChatSettingsDocument(response.result.problem.currentDocument)
        : undefined
      return {
        result: {
          oneofKind: "problem",
          problem: {
            code,
            message: requiredString(response.result.problem.message, BOT_CHAT_SETTINGS_LIMITS.problemMessage),
            currentDocument,
          },
        },
      }
    }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

export function normalizeBotChatSettingsValue(value: BotChatSettingsValue | undefined): BotChatSettingsValue | undefined {
  switch (value?.value.oneofKind) {
    case "boolValue":
      return { value: { oneofKind: "boolValue", boolValue: value.value.boolValue } }
    case "stringValue":
      return {
        value: {
          oneofKind: "stringValue",
          stringValue: boundedText(value.value.stringValue, BOT_CHAT_SETTINGS_LIMITS.textValue),
        },
      }
    case undefined:
      return undefined
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

export const normalizeBotChatSettingsItemId = (value: string): string =>
  requiredString(value, BOT_CHAT_SETTINGS_LIMITS.id)

export const normalizeBotChatSettingsRevision = (value: string): string =>
  requiredString(value, BOT_CHAT_SETTINGS_LIMITS.revision)
