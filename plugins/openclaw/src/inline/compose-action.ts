import { Method, type InlineSdkClient, type UpdateComposeAction_ComposeAction } from "@inline-chat/realtime-sdk"

// UpdateComposeAction_ComposeAction.WORKING. The server shows typing to clients
// that have not opted in to the Working status.
const INLINE_COMPOSE_ACTION_WORKING: UpdateComposeAction_ComposeAction = 6

// Agents show "Working" rather than "typing" while they run, so people don't
// mistake agent work for someone typing.
export async function sendInlineWorkingAction(
  client: Pick<InlineSdkClient, "invokeRaw">,
  params: { chatId: bigint; working: boolean },
): Promise<void> {
  await client.invokeRaw(Method.SEND_COMPOSE_ACTION, {
    oneofKind: "sendComposeAction",
    sendComposeAction: {
      peerId: { type: { oneofKind: "chat", chat: { chatId: params.chatId } } },
      ...(params.working ? { action: INLINE_COMPOSE_ACTION_WORKING } : {}),
    },
  })
}
