import { TransportPreference } from "@inline-chat/protocol/core"
import { peekServerConfig } from "@in/server/modules/serverConfig"
import { Log } from "@in/server/utils/log"

const log = new Log("ServerConfig.TransportPreference")

/**
 * Transport that upgraded bearer sessions should use, sent on every connection open. Connection
 * admission must never wait on configuration storage, so this reads the cached snapshot and any
 * failure keeps the default (V3 allowed).
 */
export const upgradedSessionTransportPreference = (): TransportPreference => {
  try {
    const setting = peekServerConfig("realtime.upgraded_session_transport")
    return setting.value === "v2" ? TransportPreference.LEGACY : TransportPreference.V3
  } catch {
    log.warn("Failed to read upgraded session transport; allowing V3")
    return TransportPreference.V3
  }
}
