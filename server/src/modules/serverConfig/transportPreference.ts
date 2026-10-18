import { TransportPreference } from "@inline-chat/protocol/core"
import { getServerConfig } from "@in/server/modules/serverConfig"
import { Log } from "@in/server/utils/log"

const log = new Log("ServerConfig.TransportPreference")

/**
 * Transport that upgraded bearer sessions should use, sent on every connection
 * open. Connection admission must never depend on configuration storage, so a
 * failed read keeps the default (V3 allowed).
 */
export const upgradedSessionTransportPreference = async (): Promise<TransportPreference> => {
  try {
    const setting = await getServerConfig("realtime.upgraded_session_transport")
    return setting.value === "v2" ? TransportPreference.LEGACY : TransportPreference.V3
  } catch {
    log.warn("Failed to read upgraded session transport; allowing V3")
    return TransportPreference.V3
  }
}
