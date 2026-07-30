import { describe, expect, test } from "bun:test"
import {
  BotChatSettingsInfo_Tone,
  BotChatSettingsProblem_Code,
  type BotChatSettingsDocument,
} from "@inline-chat/protocol/core"
import {
  BOT_CHAT_SETTINGS_LIMITS,
  normalizeBotChatSettingsDocument,
  normalizeBotChatSettingsResponse,
} from "./validation"

const document = (): BotChatSettingsDocument => ({
  version: 1,
  revision: "revision-one",
  sections: [{
    id: "essentials",
    items: [
      {
        id: "following",
        label: "Following",
        disabled: false,
        control: { oneofKind: "toggle", toggle: { value: true } },
      },
      {
        id: "reply-threads",
        label: "Reply in threads",
        disabled: false,
        control: {
          oneofKind: "select",
          select: {
            value: "auto",
            options: [
              { value: "auto", label: "Auto", disabled: false },
              { value: "on", label: "On", disabled: false },
              { value: "off", label: "Off", disabled: false },
            ],
          },
        },
      },
      {
        id: "guide",
        disabled: false,
        control: {
          oneofKind: "info",
          info: { text: "Agent decides in Auto.", tone: BotChatSettingsInfo_Tone.NEUTRAL },
        },
      },
      {
        id: "default-model",
        label: "Use as default",
        disabled: false,
        control: { oneofKind: "button", button: {} },
      },
      {
        id: "workspace",
        label: "Folder",
        disabled: false,
        control: {
          oneofKind: "folder",
          folder: {
            value: "workspace-one",
            recentFolders: [
              {
                value: "workspace-one",
                label: "inline",
                parentHint: "inline-chat",
                disabled: false,
              },
            ],
            hostInstallationId: "host-one",
            hostLabel: "Mo's MacBook Pro",
            allowsLocalPicker: true,
            localPickerPort: 51_234,
            localPickerCapability: "capability-0123456789abcdef0123456789abcdef",
          },
        },
      },
    ],
  }],
})

describe("bot chat settings validation", () => {
  test("accepts every V1 control and preserves the selected option", () => {
    const normalized = normalizeBotChatSettingsDocument(document())

    expect(normalized.sections[0]?.items).toHaveLength(5)
    expect(normalized.sections[0]?.items[1]?.control).toMatchObject({
      oneofKind: "select",
      select: { value: "auto" },
    })
  })

  test("accepts opaque folder identifiers without local paths", () => {
    const normalized = normalizeBotChatSettingsDocument(document())

    expect(normalized.sections[0]?.items[4]?.control).toMatchObject({
      oneofKind: "folder",
      folder: {
        value: "workspace-one",
        hostInstallationId: "host-one",
        recentFolders: [{ label: "inline", parentHint: "inline-chat" }],
      },
    })
  })

  test("rejects local paths and unknown folder selections", () => {
    const localPath = document()
    const localPathControl = localPath.sections[0]?.items[4]?.control
    if (localPathControl?.oneofKind !== "folder") throw new Error("missing folder fixture")
    localPathControl.folder.recentFolders[0]!.parentHint = "/Users/mo/dev"
    expect(() => normalizeBotChatSettingsDocument(localPath)).toThrow()

    const unknownSelection = document()
    const unknownSelectionControl = unknownSelection.sections[0]?.items[4]?.control
    if (unknownSelectionControl?.oneofKind !== "folder") throw new Error("missing folder fixture")
    unknownSelectionControl.folder.value = "workspace-missing"
    expect(() => normalizeBotChatSettingsDocument(unknownSelection)).toThrow()
  })

  test("requires a bounded opaque loopback endpoint only when the local picker is enabled", () => {
    const missingCapability = document()
    const missingCapabilityControl = missingCapability.sections[0]?.items[4]?.control
    if (missingCapabilityControl?.oneofKind !== "folder") throw new Error("missing folder fixture")
    missingCapabilityControl.folder.localPickerCapability = undefined
    expect(() => normalizeBotChatSettingsDocument(missingCapability)).toThrow()

    const remoteFolder = document()
    const remoteFolderControl = remoteFolder.sections[0]?.items[4]?.control
    if (remoteFolderControl?.oneofKind !== "folder") throw new Error("missing folder fixture")
    remoteFolderControl.folder.allowsLocalPicker = false
    remoteFolderControl.folder.localPickerPort = undefined
    remoteFolderControl.folder.localPickerCapability = undefined
    expect(normalizeBotChatSettingsDocument(remoteFolder)).toBeDefined()

    const invalidPort = document()
    const invalidPortControl = invalidPort.sections[0]?.items[4]?.control
    if (invalidPortControl?.oneofKind !== "folder") throw new Error("missing folder fixture")
    invalidPortControl.folder.localPickerPort = 80
    expect(() => normalizeBotChatSettingsDocument(invalidPort)).toThrow()
  })

  test("rejects duplicate item identifiers across sections", () => {
    const value = document()
    value.sections.push({
      id: "another-section",
      items: [{
        id: "following",
        label: "Duplicate",
        disabled: false,
        control: { oneofKind: "button", button: {} },
      }],
    })

    expect(() => normalizeBotChatSettingsDocument(value)).toThrow()
  })

  test("rejects documents above the global item cap", () => {
    const value = document()
    value.sections = [{
      id: "too-many",
      items: Array.from({ length: BOT_CHAT_SETTINGS_LIMITS.items + 1 }, (_, index) => ({
        id: `item-${index}`,
        label: `Item ${index}`,
        disabled: false,
        control: { oneofKind: "button" as const, button: {} },
      })),
    }]

    expect(() => normalizeBotChatSettingsDocument(value)).toThrow()
  })

  test("bots cannot forge the server-owned unreachable state", () => {
    expect(() => normalizeBotChatSettingsResponse({
      result: {
        oneofKind: "problem",
        problem: {
          code: BotChatSettingsProblem_Code.UNREACHABLE,
          message: "Trust me",
        },
      },
    })).toThrow()
  })
})
