import { InputPeer, Member_Role } from "@in/protocol/core"
import type { TPeerInfo } from "@in/server/api-types"
import { type DbMemberRole } from "@in/server/db/schema"

export const ProtocolConvertors = {
  dbMemberRoleToProtocol: (dbMemberRole: DbMemberRole): Member_Role => {
    switch (dbMemberRole) {
      case "owner":
        return Member_Role.OWNER
      case "admin":
        return Member_Role.ADMIN
      case "member":
        return Member_Role.MEMBER
    }
  },

  protocolMemberRoleToDb: (protocolMemberRole: Member_Role): DbMemberRole => {
    switch (protocolMemberRole) {
      case Member_Role.OWNER:
        return "owner"
      case Member_Role.ADMIN:
        return "admin"
      case Member_Role.MEMBER:
        return "member"
    }
  },

  zodPeerToProtocolInputPeer: (peer: TPeerInfo): InputPeer => {
    if ("userId" in peer) {
      return {
        type: {
          oneofKind: "user",
          user: {
            userId: BigInt(peer.userId),
          },
        },
      }
    }

    if ("threadId" in peer) {
      return {
        type: {
          oneofKind: "user",
          user: {
            userId: BigInt(peer.threadId),
          },
        },
      }
    }

    throw new Error("Invalid peer")
  },
}
