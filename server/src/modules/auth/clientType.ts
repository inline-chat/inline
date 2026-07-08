import { clientTypeEnum } from "@in/server/db/schema/sessions"
import { Log } from "@in/server/utils/log"

type AuthClientType = (typeof clientTypeEnum.enumValues)[number]

const fallbackUnknownClientType: AuthClientType = "api"
const knownClientTypes = new Set<AuthClientType>(clientTypeEnum.enumValues)

export function normalizeAuthClientType(clientType: string | undefined | null, source: string): AuthClientType | undefined {
  const normalized = clientType?.trim()
  if (!normalized) {
    return undefined
  }

  if (isKnownClientType(normalized)) {
    return normalized
  }

  Log.shared.warn("Unknown auth clientType; defaulting", {
    source,
    clientType: normalized,
    fallbackClientType: fallbackUnknownClientType,
  })

  return fallbackUnknownClientType
}

function isKnownClientType(clientType: string): clientType is AuthClientType {
  return knownClientTypes.has(clientType as AuthClientType)
}
