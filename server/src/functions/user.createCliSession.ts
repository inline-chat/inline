import type { CreateCliSessionInput, CreateCliSessionResult } from "@inline-chat/protocol/core"
import { SessionsModel } from "@in/server/db/models/sessions"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { generateToken } from "@in/server/utils/auth"
import { Log } from "@in/server/utils/log"
import { validateUpToFourSegementSemver } from "@in/server/utils/validate"

const log = new Log("user.createCliSession")
const CLI_DEVICE_ID_PATTERN = /^cli_[A-Za-z0-9_-]{16,96}$/
const MAX_DEVICE_NAME_LENGTH = 128

export async function createCliSession(
  input: CreateCliSessionInput,
  context: FunctionContext,
): Promise<CreateCliSessionResult> {
  const sourceSession = await SessionsModel.getById(context.currentSessionId)
  if (
    !sourceSession ||
    sourceSession.userId !== context.currentUserId ||
    sourceSession.revoked !== null ||
    sourceSession.clientType !== "macos"
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const deviceId = input.deviceId.trim()
  const deviceName = normalizeOptionalLabel(input.deviceName, MAX_DEVICE_NAME_LENGTH)
  const clientVersion = input.clientVersion.trim()
  const osVersion = normalizeOptionalVersion(input.osVersion)

  if (!CLI_DEVICE_ID_PATTERN.test(deviceId) || !validateUpToFourSegementSemver(clientVersion)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.deviceName !== undefined && deviceName === undefined) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.osVersion !== undefined && osVersion === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  const { token, tokenHash } = await generateToken(context.currentUserId)
  const session = await SessionsModel.create({
    userId: context.currentUserId,
    tokenHash,
    deviceId,
    personalData: {
      deviceName,
      country: sourceSession.personalData.country,
      region: sourceSession.personalData.region,
      city: sourceSession.personalData.city,
      timezone: sourceSession.personalData.timezone,
    },
    clientType: "cli",
    clientVersion,
    osVersion,
  })

  log.info("Created CLI session through macOS local handoff", {
    userId: context.currentUserId,
    sourceSessionId: context.currentSessionId,
    sessionId: session.id,
    deviceId,
    clientVersion,
  })

  return { token, sessionId: BigInt(session.id), userId: BigInt(context.currentUserId) }
}

function normalizeOptionalLabel(value: string | undefined, maxLength: number): string | undefined {
  if (value === undefined) return undefined
  const normalized = value.trim()
  if (!normalized || normalized.length > maxLength || containsControlCharacters(normalized)) {
    return undefined
  }
  return normalized
}

function containsControlCharacters(value: string): boolean {
  return [...value].some((character) => {
    const codePoint = character.codePointAt(0)
    return codePoint !== undefined && (codePoint <= 0x1f || codePoint === 0x7f)
  })
}

function normalizeOptionalVersion(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  const normalized = value.trim()
  return validateUpToFourSegementSemver(normalized) ? normalized : undefined
}
