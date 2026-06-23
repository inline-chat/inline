import {
  CHATGPT_AGENT_KEY,
  CHATGPT_BOT_ALIASES,
  CHATGPT_CONNECTION_PROVIDER,
} from "@inline-chat/agent-chatgpt"
import { normalizeUsername } from "@in/server/utils/normalize"

export type InternalAgentAlias = string

export type InternalAgentRegistration = {
  readonly agentKey: string
  readonly botUsername: string
  readonly displayName: string
  readonly connectionProvider: string
  readonly official: boolean
  readonly aliases: readonly InternalAgentAlias[]
  readonly commands: readonly InternalAgentCommand[]
  readonly profilePhotoAsset?: InternalAgentProfilePhotoAsset
}

export type InternalAgentCommand = {
  readonly command: string
  readonly description: string
  readonly sortOrder?: number
}

export type InternalAgentProfilePhotoAsset = {
  readonly url: URL
  readonly fileName: string
  readonly mimeType: string
  readonly replacesFileNames?: readonly string[]
}

export const INTERNAL_AGENT_REGISTRATIONS = [
  {
    agentKey: CHATGPT_AGENT_KEY,
    botUsername: "chatgpt",
    displayName: "ChatGPT",
    connectionProvider: CHATGPT_CONNECTION_PROVIDER,
    official: true,
    aliases: CHATGPT_BOT_ALIASES,
    commands: [
      {
        command: "stop",
        description: "Stop the current ChatGPT run",
        sortOrder: 0,
      },
    ],
    profilePhotoAsset: {
      url: new URL("./assets/openai-black-monoblossom-white.png", import.meta.url),
      fileName: "openai-black-monoblossom-white.png",
      mimeType: "image/png",
      replacesFileNames: ["openai-black-monoblossom.png"],
    },
  },
] as const satisfies readonly InternalAgentRegistration[]

const aliases = new Map<string, InternalAgentRegistration>()

for (const registration of INTERNAL_AGENT_REGISTRATIONS) {
  for (const alias of registration.aliases) {
    aliases.set(normalizeAlias(alias), registration)
  }
}

export function resolveInternalAgentAlias(value: string): InternalAgentRegistration | undefined {
  return aliases.get(normalizeAlias(value))
}

export function listInternalAgentRegistrations(): readonly InternalAgentRegistration[] {
  return INTERNAL_AGENT_REGISTRATIONS
}

function normalizeAlias(value: string): string {
  return normalizeUsername(value).toLowerCase()
}
