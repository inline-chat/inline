import {
  InlineSdkClient,
  Method,
  Member_Role,
  type User,
} from "@inline-chat/realtime-sdk"

export type InlineSpaceMemberRecord = {
  userId: string
  role: "owner" | "admin" | "member" | null
  canAccessPublicChats: boolean | undefined
  date: number
  user: {
    id: string
    name: string
    username: string | null
  } | null
}

export function buildInlineUserDisplayName(user: {
  firstName?: string
  lastName?: string
  username?: string
}): string {
  const explicit = [user.firstName?.trim(), user.lastName?.trim()].filter(Boolean).join(" ")
  if (explicit) return explicit
  const username = user.username?.trim()
  if (username) return `@${username}`
  return "Unknown"
}

function buildUserMap(users: User[]): Map<string, User> {
  const map = new Map<string, User>()
  for (const user of users) {
    map.set(String(user.id), user)
  }
  return map
}

function mapSpaceMemberRole(role: Member_Role | undefined): "owner" | "admin" | "member" | null {
  if (role == null) return null
  if (role === Member_Role.OWNER) return "owner"
  if (role === Member_Role.ADMIN) return "admin"
  if (role === Member_Role.MEMBER) return "member"
  return null
}

export async function getSpaceMembersWithUsers(params: {
  client: InlineSdkClient
  spaceId: bigint
}): Promise<InlineSpaceMemberRecord[]> {
  const membersResult = await params.client.invokeRaw(Method.GET_SPACE_MEMBERS, {
    oneofKind: "getSpaceMembers",
    getSpaceMembers: {
      spaceId: params.spaceId,
    },
  })
  if (membersResult.oneofKind !== "getSpaceMembers") {
    throw new Error(`inline members: expected getSpaceMembers result, got ${String(membersResult.oneofKind)}`)
  }

  const usersById = buildUserMap(membersResult.getSpaceMembers.users ?? [])
  return (membersResult.getSpaceMembers.members ?? []).map((member) => {
    const linkedUser = usersById.get(String(member.userId))
    return {
      userId: String(member.userId),
      role: mapSpaceMemberRole(member.role),
      canAccessPublicChats: member.canAccessPublicChats,
      date: Number(member.date) * 1000,
      user: linkedUser
        ? {
            id: String(linkedUser.id),
            name: buildInlineUserDisplayName(linkedUser),
            username: linkedUser.username ?? null,
          }
        : null,
    }
  })
}
