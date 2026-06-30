import type {
  CreateUserGroupInput,
  CreateUserGroupResult,
  DeleteUserGroupInput,
  DeleteUserGroupResult,
  GetUserGroupsInput,
  GetUserGroupsResult,
  UpdateUserGroupInput,
  UpdateUserGroupResult,
} from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"

const context = (handlerContext: HandlerContext) => ({
  currentUserId: handlerContext.userId,
  currentSessionId: handlerContext.sessionId,
})

export async function getUserGroupsHandler(
  input: GetUserGroupsInput,
  handlerContext: HandlerContext,
): Promise<GetUserGroupsResult> {
  return Functions.spaces.getUserGroups(
    {
      spaceId: Number(input.spaceId),
    },
    context(handlerContext),
  )
}

export async function createUserGroupHandler(
  input: CreateUserGroupInput,
  handlerContext: HandlerContext,
): Promise<CreateUserGroupResult> {
  return Functions.spaces.createUserGroup(
    {
      spaceId: Number(input.spaceId),
      name: input.name,
      description: input.description,
      userIds: input.userIds.map((id) => Number(id)),
    },
    context(handlerContext),
  )
}

export async function updateUserGroupHandler(
  input: UpdateUserGroupInput,
  handlerContext: HandlerContext,
): Promise<UpdateUserGroupResult> {
  return Functions.spaces.updateUserGroup(
    {
      groupId: Number(input.groupId),
      name: input.name,
      description: input.description,
      userIds: input.userIds.map((id) => Number(id)),
    },
    context(handlerContext),
  )
}

export async function deleteUserGroupHandler(
  input: DeleteUserGroupInput,
  handlerContext: HandlerContext,
): Promise<DeleteUserGroupResult> {
  await Functions.spaces.deleteUserGroup(
    {
      groupId: Number(input.groupId),
    },
    context(handlerContext),
  )

  return {}
}
