import { Member_Role, type Member } from "@in/protocol/core"
import type { DbMember } from "@in/server/db/schema"
import { encodeDate } from "@in/server/realtime/encoders/helpers"

// New encoders for Member and MinUser
export function encodeMember(member: DbMember): Member {
  let protocolRole: Member_Role | undefined

  if (member.role === "admin") {
    protocolRole = Member_Role.ADMIN
  } else if (member.role === "member") {
    protocolRole = Member_Role.MEMBER
  } else if (member.role === "owner") {
    protocolRole = Member_Role.OWNER
  } else {
    protocolRole = Member_Role.UNKNOWN
  }

  return {
    id: BigInt(member.id),
    spaceId: BigInt(member.spaceId),
    userId: BigInt(member.userId),
    role: protocolRole,
    date: encodeDate(member.date) ?? 0n,
  }
}
