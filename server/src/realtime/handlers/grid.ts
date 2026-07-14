import type {
  CreateGridRoomInput,
  CreateGridRoomResult,
  DeleteGridRoomInput,
  DeleteGridRoomResult,
  GetGridInput,
  GetGridResult,
  GetGridHomeInput,
  GetGridHomeResult,
  JoinGridRoomInput,
  JoinGridRoomResult,
  LeaveGridRoomInput,
  LeaveGridRoomResult,
  PrepareGridConnectionInput,
  PrepareGridConnectionResult,
  SetGridAvatarMicrophoneEnabledInput,
  SetGridAvatarMicrophoneEnabledResult,
  SetGridRoomLockedInput,
  SetGridRoomLockedResult,
  SetGridRoomTitleInput,
  SetGridRoomTitleResult,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"

const functionContext = (context: HandlerContext) => ({
  currentSessionId: context.sessionId,
  currentUserId: context.userId,
})

export const getGridHandler = (input: GetGridInput, context: HandlerContext): Promise<GetGridResult> =>
  Functions.grid.get(input, functionContext(context))

export const getGridHomeHandler = (
  input: GetGridHomeInput,
  context: HandlerContext,
): Promise<GetGridHomeResult> => Functions.grid.getHome(input, functionContext(context))

export const createGridRoomHandler = (
  input: CreateGridRoomInput,
  context: HandlerContext,
): Promise<CreateGridRoomResult> => Functions.grid.createRoom(input, functionContext(context))

export const joinGridRoomHandler = (
  input: JoinGridRoomInput,
  context: HandlerContext,
): Promise<JoinGridRoomResult> => Functions.grid.joinRoom(input, functionContext(context))

export const leaveGridRoomHandler = (
  input: LeaveGridRoomInput,
  context: HandlerContext,
): Promise<LeaveGridRoomResult> => Functions.grid.leaveRoom(input, functionContext(context))

export const setGridRoomTitleHandler = (
  input: SetGridRoomTitleInput,
  context: HandlerContext,
): Promise<SetGridRoomTitleResult> => Functions.grid.setRoomTitle(input, functionContext(context))

export const setGridRoomLockedHandler = (
  input: SetGridRoomLockedInput,
  context: HandlerContext,
): Promise<SetGridRoomLockedResult> => Functions.grid.setRoomLocked(input, functionContext(context))

export const deleteGridRoomHandler = (
  input: DeleteGridRoomInput,
  context: HandlerContext,
): Promise<DeleteGridRoomResult> => Functions.grid.deleteRoom(input, functionContext(context))

export const prepareGridConnectionHandler = (
  input: PrepareGridConnectionInput,
  context: HandlerContext,
): Promise<PrepareGridConnectionResult> => Functions.grid.prepareConnection(input, functionContext(context))

export const setGridAvatarMicrophoneEnabledHandler = (
  input: SetGridAvatarMicrophoneEnabledInput,
  context: HandlerContext,
): Promise<SetGridAvatarMicrophoneEnabledResult> =>
  Functions.grid.setAvatarMicrophoneEnabled(input, functionContext(context))
