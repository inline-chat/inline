/** The chat pane: the chat header, the message list and the composer for one chat. See `web/src/app/README.md`. */

export { ChatPane, type ChatPaneProps } from "./ChatPane"
export { ChatHeader, subtitleText } from "./ChatHeader"
export {
  ChatPaneModel,
  OpenChat,
  chatPaneTarget,
  followDraft,
  paneDestination,
  type ChatPaneHooks,
  type ChatPaneOptions,
  type ChatPaneSession,
  type ChatPaneTarget,
} from "./chat-pane-model"
export { createChatComposer, type ChatComposer, type ChatComposerDeps } from "./chat-composer"
