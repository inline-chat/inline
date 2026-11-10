import { AgentOutputMode, Method, type InlineSdkClient } from "@inline-chat/realtime-sdk"
import { buildChatPeer } from "./monitor-shared.js"

function selectedMode(value: AgentOutputMode | undefined) {
  if (value === AgentOutputMode.DETAILED) return "detailed"
  if (value === AgentOutputMode.FRIENDLY) return "friendly"
  return undefined
}

/** Read the user's choices once for this turn. An absent choice leaves presentation to the host. */
export async function readInlineOutputMode(client: InlineSdkClient, botUserId: bigint, chatId: bigint, signal: AbortSignal) {
  const options = { signal: AbortSignal.any([signal, AbortSignal.timeout(1_500)]) }
  const [participations, settings] = await Promise.all([
    client.invokeRaw(Method.GET_AGENT_PARTICIPATIONS, {
      oneofKind: "getAgentParticipations", getAgentParticipations: { peerId: buildChatPeer(chatId) },
    }, options).catch(() => undefined),
    client.invokeRaw(Method.GET_AGENT_SETTINGS, {
      oneofKind: "getAgentSettings", getAgentSettings: { botUserId: 0n },
    }, options).catch(() => undefined),
  ])
  signal.throwIfAborted()
  // If we couldn't check the chat override, keep this turn quiet. A more
  // verbose bot default could conflict with the user's choice for this chat.
  if (participations?.oneofKind !== "getAgentParticipations") return "unavailable"
  const own = participations.getAgentParticipations.participations.find((row) => row.botUserId === botUserId)
  const override = selectedMode(own?.outputMode)
  if (override) return override
  if (settings?.oneofKind !== "getAgentSettings") return "unavailable"
  return selectedMode(settings.getAgentSettings.settings?.defaultOutputMode)
}
