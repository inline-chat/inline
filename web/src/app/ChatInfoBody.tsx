/**
 * The chat info pane's body, part of its chunk (`chat-info-chunk.ts`): the
 * model for the destination's chat (`chat-info-pane.ts` wires it to the
 * session, the pane and the app's services) and `ChatInfoPane`. Keyed by chat
 * by its host (`ChatInfoPaneView.tsx`), so another chat makes another model.
 *
 * The media tabs use the session's media layer (`ShellModel.mediaSources`,
 * the same one the message lists use, so a thumbnail held by both is
 * fetched once; this chunk imports its factory, which the bundler shares
 * with the content chunk), open photos and videos in the app's viewer, and
 * save files as the message list does.
 */

import type { ChatID } from "@inline/ids"
import { useModel } from "@inline/reactive/react"
import type { ChatInfoTab, PaneId } from "@inline/view"
import { ChatInfoPane, createChatInfoModel, type ChatInfoModel } from "../features/chat-info"
import { downloadMessageFile } from "../features/chat/download"
import { createCoreMediaSources } from "../features/media/sources"
import { chatInfoOptions } from "./chat-info-pane"
import type { AppServices } from "./services"
import type { ShellModel } from "./shell-model"

export function ChatInfoBody(props: {
  services: AppServices
  shell: ShellModel
  paneId: PaneId
  chatId: ChatID
  tab: ChatInfoTab | undefined
}) {
  const { services, shell } = props
  const model = useModel(() => {
    const session = shell.session
    const toast = (input: { id?: string; title: string; description?: string; tone?: "neutral" | "success" | "warning" | "error" }) =>
      void shell.toasts.show({ duration: 4000, ...input })
    let made: ChatInfoModel | undefined
    made = createChatInfoModel(
      chatInfoOptions({
        session,
        paneId: props.paneId,
        chatId: props.chatId,
        ...(props.tab ? { tab: props.tab } : {}),
        copyText: services.copyText,
        toast,
        model: () => made,
        media: {
          sources: () => shell.mediaSources(() => createCoreMediaSources({ client: session.client })),
          ...(shell.mediaViewer ? { openMedia: (input, rows, sources) => void shell.mediaViewer?.open({ input, rows, sources }) } : {}),
          download: ({ rowId, media }) =>
            void downloadMessageFile(
              {
                client: session.client,
                target: (id) => {
                  const target = session.actions.target(id)
                  return target?.messageId !== undefined ? { chatId: target.chatId, messageId: target.messageId } : undefined
                },
                toast,
              },
              rowId,
              media,
            ),
          // App links open in the app, as in messages; others in a new tab through the platform's allowlist.
          openLink: (url) => {
            const destination = services.parseAppLink(url)
            if (destination) void session.workspace.open(destination)
            else services.openExternal(url)
          },
        },
      }),
    )
    return made
  }, [shell, props.paneId, props.chatId])
  return <ChatInfoPane model={model} />
}
