import { Method, UpdateComposeAction_ComposeAction, type InlineSdkClient } from "@inline-chat/realtime-sdk"

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
      ...(params.working ? { action: UpdateComposeAction_ComposeAction.WORKING } : {}),
    },
  })
}
