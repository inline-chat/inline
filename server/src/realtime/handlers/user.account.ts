import {
  type Update,
  type User as ProtocolUser,
  UsernameAvailability,
  type ChangeUsernameInput,
  type ChangeUsernameResult,
  type CheckUsernameInput,
  type CheckUsernameResult,
  type UpdateProfileInput,
  type UpdateProfileResult,
  type SetProfilePhotoInput,
  type SetProfilePhotoResult,
  type GetExternalProfilePhotoInput,
  type GetExternalProfilePhotoResult,
  ExternalProfilePhotoStatus,
} from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { db } from "@in/server/db"
import { files, lower, users, type DbFile, type DbNewUser, type DbUser } from "@in/server/db/schema"
import { getFileByUniqueId } from "@in/server/db/models/files"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { HandlerContext } from "@in/server/realtime/types"
import { isReservedUsername } from "@in/server/modules/users/reservedUsernames"
import { normalizeUsername } from "@in/server/utils/normalize"
import {
  externalProfilePhotoResolver,
  normalizeExternalUsername,
} from "@in/server/modules/users/externalProfilePhoto"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { eq } from "drizzle-orm"

const USERNAME_UNIQUE_CONSTRAINT = "users_username_unique"
const externalProfilePhotoRateLimiter = new InMemoryRateLimiter()
const EXTERNAL_PROFILE_PHOTO_RATE_LIMIT = { max: 10, windowMs: 10 * 60_000 }

export const checkUsernameHandler = async (
  input: CheckUsernameInput,
  context: HandlerContext,
): Promise<CheckUsernameResult> => {
  const username = normalizeUsername(input.username)
  const availability = await usernameAvailability(username, context.userId)

  return {
    username,
    availability,
  }
}

export const changeUsernameHandler = async (
  input: ChangeUsernameInput,
  context: HandlerContext,
): Promise<ChangeUsernameResult> => {
  const username = normalizeUsername(input.username)

  if (!username) {
    const { user, update } = await updateUserAndPush(context, { username: null })
    return { user: encodeUser({ user }), updates: [update] }
  }

  const availability = await usernameAvailability(username, context.userId)
  switch (availability) {
    case UsernameAvailability.USERNAME_AVAILABLE:
    case UsernameAvailability.USERNAME_CURRENT: {
      const { user, update } = await updateUserAndPush(context, { username, pendingSetup: false }).catch(
        (error: unknown) => {
          if (isUsernameUniqueError(error)) {
            throw RealtimeRpcError.UsernameTaken()
          }
          throw error
        },
      )
      return { user: encodeUser({ user }), updates: [update] }
    }
    case UsernameAvailability.USERNAME_INVALID:
      throw RealtimeRpcError.UsernameInvalid()
    case UsernameAvailability.USERNAME_TAKEN:
    case UsernameAvailability.USERNAME_RESERVED:
      throw RealtimeRpcError.UsernameTaken()
    case UsernameAvailability.USERNAME_AVAILABILITY_UNSPECIFIED:
      throw RealtimeRpcError.BadRequest()
  }
}

export const updateProfileHandler = async (
  input: UpdateProfileInput,
  context: HandlerContext,
): Promise<UpdateProfileResult> => {
  const props: DbNewUser = {}

  if (input.firstName !== undefined) {
    const firstName = input.firstName.trim()
    if (!firstName) {
      throw RealtimeRpcError.FirstNameInvalid()
    }
    props.firstName = firstName
  }

  if (input.lastName !== undefined) {
    const lastName = input.lastName.trim()
    props.lastName = lastName || null
  }

  if (input.bio !== undefined) {
    const bio = input.bio.trim()
    props.bio = bio || null
  }

  if (Object.keys(props).length === 0) {
    const user = await getUser(context.userId)
    return { user: encodeUser({ user }), updates: [] }
  }

  const { user, update } = await updateUserAndPush(context, props)
  return { user: encodeUser({ user }), updates: [update] }
}

export const setProfilePhotoHandler = async (
  input: SetProfilePhotoInput,
  context: HandlerContext,
): Promise<SetProfilePhotoResult> => {
  const fileUniqueId = input.fileUniqueId.trim()
  let photoFile: DbFile | undefined

  if (fileUniqueId) {
    photoFile = await getFileByUniqueId(fileUniqueId)
    if (!photoFile || photoFile.userId !== context.userId || photoFile.fileType !== "photo") {
      throw RealtimeRpcError.BadRequest()
    }
  }

  const { user, update } = await updateUserAndPush(
    context,
    { photoFileId: photoFile?.id ?? null },
  )
  return { user: encodeUser({ user, photoFile }), updates: [update] }
}

export const getExternalProfilePhotoHandler = async (
  input: GetExternalProfilePhotoInput,
  context: HandlerContext,
): Promise<GetExternalProfilePhotoResult> => {
  const username = normalizeExternalUsername(input.provider, input.username)
  if (!username) {
    throw RealtimeRpcError.BadRequest()
  }

  const rateLimit = externalProfilePhotoRateLimiter.consume({
    key: `external-profile-photo:${context.userId}`,
    nowMs: Date.now(),
    rule: EXTERNAL_PROFILE_PHOTO_RATE_LIMIT,
  })
  if (!rateLimit.allowed) {
    return {
      status: ExternalProfilePhotoStatus.EXTERNAL_PROFILE_PHOTO_UNAVAILABLE,
      photo: new Uint8Array(),
      mimeType: "",
    }
  }

  return externalProfilePhotoResolver.resolve(input.provider, username)
}

async function usernameAvailability(username: string, currentUserId: number): Promise<UsernameAvailability> {
  if (username.length < 2) {
    return UsernameAvailability.USERNAME_INVALID
  }

  const normalized = username.toLowerCase()
  const result = await db._query.users.findFirst({
    where: eq(lower(users.username), normalized),
    columns: { id: true },
  })

  if (result) {
    return result.id === currentUserId
      ? UsernameAvailability.USERNAME_CURRENT
      : UsernameAvailability.USERNAME_TAKEN
  }

  if (isReservedUsername(normalized)) {
    return UsernameAvailability.USERNAME_RESERVED
  }

  return UsernameAvailability.USERNAME_AVAILABLE
}

async function updateUserAndPush(
  context: HandlerContext,
  props: DbNewUser,
): Promise<{ user: DbUser; update: Update }> {
  const { user, update } = await db.transaction(async (tx) => {
    const [user] = await tx.update(users).set(props).where(eq(users.id, context.userId)).returning()
    if (!user) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const currentPhotoFile = user.photoFileId
      ? await tx.select().from(files).where(eq(files.id, user.photoFileId)).limit(1).then((rows) => rows[0])
      : undefined
    const protocolUser = encodeUser({ user, photoFile: currentPhotoFile })
    const serverUpdate: ServerUpdate["update"] = {
      oneofKind: "updatedUser",
      updatedUser: {
        user: protocolUser,
      },
    }
    const seqDate = await UserBucketUpdates.enqueue({ userId: context.userId, update: serverUpdate }, { tx })

    return {
      user,
      update: updatedUserUpdate(protocolUser, seqDate),
    }
  })

  RealtimeUpdates.pushToUser(context.userId, [update], { skipSessionId: context.sessionId })

  return { user, update }
}

function updatedUserUpdate(user: ProtocolUser, seqDate: UpdateSeqAndDate): Update {
  return {
    seq: seqDate.seq,
    date: encodeDateStrict(seqDate.date),
    update: {
      oneofKind: "updatedUser",
      updatedUser: {
        user,
      },
    },
  }
}

function isUsernameUniqueError(error: unknown): boolean {
  if (!error || typeof error !== "object") {
    return false
  }

  const record = error as Record<string, unknown>
  return (
    record["code"] === "23505" &&
    (record["constraint"] === USERNAME_UNIQUE_CONSTRAINT ||
      record["constraint_name"] === USERNAME_UNIQUE_CONSTRAINT ||
      String(record["message"] ?? "").includes(USERNAME_UNIQUE_CONSTRAINT))
  )
}

async function getUser(userId: number): Promise<DbUser> {
  const user = await db._query.users.findFirst({
    where: eq(users.id, userId),
  })
  if (!user) {
    throw RealtimeRpcError.UserIdInvalid()
  }
  return user
}
