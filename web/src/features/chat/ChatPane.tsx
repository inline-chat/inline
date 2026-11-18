/**
 * The chat pane: the title strip with the chat header, the message list
 * (`TimelineView` over the chat's timeline controller, rows from the message
 * views) and the composer (`ComposerView` over a composer model fed by the
 * chat). One `ChatPaneModel` per pane follows the pane's destination; a
 * switch to another chat swaps the chat inside the same pane. The pane's
 * message content (`ChatContent`, its own chunk) lives as long as the pane.
 *
 * Per chat shown (all disposed on a switch): find in chat (`ChatFind`, the
 * bar over the message area once Mod+F loaded it), `@` suggestions
 * (`ChatMentions`), this user's typing (`createComposeReporter`, inside the
 * composer), the chat's attachments (`LazyAttachments`) and the drop target
 * over the pane.
 */

import { receivedMessageRowId, rowKey, type MessageRow, type UserRow } from "@inline/core-protocol"
import { userAvatarSeed, userDisplayName, userShortName } from "@inline/chat-ui"
import type { UserID } from "@inline/ids"
import { browserClock, effect, untracked } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { IconButton } from "@inline/ui/react"
import type { PaneId } from "@inline/view"
import { actionHandle } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { FOCUS_REGION_ATTRIBUTE } from "../../app/focus"
import { combinedSuggest } from "../../app/emoji-session"
import type { AppServices } from "../../app/services"
import type { ShellModel } from "../../app/shell-model"
import { storageFullComposerNote } from "../../app/status"
import { TitleStrip } from "../../app/TitleStrip"
import { DropOverlay } from "../composer/AttachmentStrip"
import { ComposerView } from "../composer/ComposerView"
import type { FindSender } from "../find/find-bar-controller"
import { MessageActionsController, MessageActionsRegion } from "../message"
import { createTimelineSurface, TimelineView } from "../timeline"
import { createComposeReporter } from "../typing/outgoing"
import { EmojiIcon } from "../../app/icons"
import { chatDropTarget } from "./chat-attachments"
import { createChatComposer } from "./chat-composer"
import { ComposerEmojiSlot } from "./composer-emoji"
import { ChatContent } from "./chat-content"
import { ChatFind } from "./chat-find"
import { ChatMentions } from "./chat-mentions"
import { ChatPaneModel, paneDestination, type OpenChat } from "./chat-pane-model"
import { ChatHeader } from "./ChatHeader"
import { createRenderItem } from "./ChatMessages"

export type ChatPaneProps = {
  readonly services: AppServices
  readonly shell: ShellModel
  readonly paneId: PaneId
  /** Controls at the leading edge of the title strip. */
  readonly leading?: ReactNode
}

/** The rows of a chat's loaded window, oldest first (the media viewer steps through their media). */
const windowRows = (chat: OpenChat | undefined): MessageRow[] => {
  if (!chat) return []
  const rows: MessageRow[] = []
  for (const key of chat.model.rowKeys.peek()) {
    const row = chat.model.row(key).peek()
    if (row) rows.push(row)
  }
  return rows
}

export function ChatPane(props: ChatPaneProps) {
  const { services, shell, paneId } = props
  const pane = useModel(() => {
    const { metrics, unsavedWork } = services.runtime
    const model = new ChatPaneModel({
      session: shell.session,
      timeZone: services.timeZone,
      clock: services.timelineClock,
      frames: services.frames,
      hooks: {
        onSwitch: () => metrics.chatSwitchStarted(),
        onRowsShown: () => {
          metrics.markAfterPaint("chatRows")
          metrics.chatSwitchPainted()
        },
        trackSend: (work) => void unsavedWork.track(work),
        onStage: (stage, chatId) => metrics.stage(stage, { chatId }),
        onChat: (chat) => {
          if (chat) services.runtime.openChats.set(paneId, chat)
          else services.runtime.openChats.delete(paneId)
        },
      },
    })
    model.follow(paneDestination(shell.session.workspace, paneId))
    return model
  }, [shell, paneId])
  const content = useModel(() => {
    const session = shell.session
    return new ChatContent({
      chunk: services.views.content,
      peekRow: (key) => session.client.store.peekRow(key),
      userId: session.userId,
      currentChatId: () => pane.current.peek()?.chatId,
      open: (destination, intent) => void session.workspace.open(destination, intent ? { intent } : {}),
      threadsInSidePane: () => services.preferences.replyThreadsInSidePane.peek(),
      parseAppLink: services.parseAppLink,
      openExternal: services.openExternal,
      copyText: (text) => void services.copyText(text),
      compose: (text) => void shell.composeInPane(paneId, text),
      mediaSources: (chunk) => shell.mediaSources(() => chunk.createCoreMediaSources({ client: session.client })),
      invokeAction: (rowId, actionId) => {
        const target = session.actions.target(rowId)
        return target ? session.actions.invokeAction(target, actionId) : undefined
      },
      submitForm: (rowId, formId, values) => {
        const chat = pane.current.peek()
        const target = session.actions.target(rowId)
        if (!chat || !target || target.chatId !== chat.chatId || target.messageId === undefined) return undefined
        return chat.model.submitForm(target.messageId, formId, values)
      },
      confirm: (request) => shell.messageActions.ask(request),
      toast: (toast) => void shell.toasts.show({ duration: 4000, ...toast }),
      files: {
        client: session.client,
        target: (rowId) => {
          const target = session.actions.target(rowId)
          return target?.messageId !== undefined ? { chatId: target.chatId, messageId: target.messageId } : undefined
        },
      },
      ...(shell.mediaViewer
        ? {
            openMedia: (input, sources) =>
              void shell.mediaViewer?.open({ input, sources, rows: () => windowRows(pane.current.peek()) }),
          }
        : {}),
    })
  }, [shell, pane])
  const chat = useSignal(pane.current)
  if (!chat) return <TitleStrip leading={props.leading} />
  return <ChatView key={chat.chatId} chat={chat} content={content} {...props} />
}

function ChatView(props: ChatPaneProps & { chat: OpenChat; content: ChatContent }) {
  const { chat, services, shell, paneId, content } = props
  const session = shell.session
  const surface = useModel(
    () =>
      createTimelineSurface({
        controller: chat.timeline,
        window: chat.timelineWindow,
        clock: services.timelineClock,
        frames: services.frames,
      }),
    [chat],
  )
  useModel(() => ({ dispose: shell.registerTimeline(paneId, () => surface.focus()) }), [shell, paneId, surface])
  const mentions = useModel(
    () =>
      new ChatMentions({
        chatId: chat.chatId,
        viewerId: session.userId,
        client: session.client,
        chat: chat.model,
        chunk: services.views.mentions,
        notify: (notice) =>
          void shell.toasts.show({
            duration: 6000,
            tone: "neutral",
            title: notice.title,
            ...(notice.description !== undefined ? { description: notice.description } : {}),
            ...(notice.tone ? { tone: notice.tone } : {}),
            ...(notice.action ? { action: { label: notice.action.label, onAction: notice.action.onAction } } : {}),
          }),
        nameOf: (userId) => {
          const user = session.client.store.peekRow(rowKey("user", userId)) as UserRow | undefined
          return user ? userShortName(user) : undefined
        },
        // Rule 14: add the people a send mentioned (at once with Undo, or after asking).
        addParticipants: (userIds) =>
          actionHandle(session.client.intent({ kind: "addChatParticipants", chatId: chat.chatId, userIds: [...userIds] }), "add them to this thread", {
            store: session.client.store,
            tracker: session.intents,
          }),
        removeParticipant: (userId) =>
          actionHandle(session.client.intent({ kind: "removeChatParticipant", chatId: chat.chatId, userId }), "remove them from this thread", {
            store: session.client.store,
            tracker: session.intents,
          }),
        ask: (request) => shell.messageActions.ask(request),
      }),
    [chat],
  )
  const attachments = useModel(() => shell.attachments?.forChat(chat.chatId), [chat])
  const composer = useModel(
    () =>
      createChatComposer({
        chat,
        paneId,
        safeUrl: services.safeUrl,
        shell,
        unsaved: services.runtime.unsavedWork,
        focusTimeline: () => void surface.focus(),
        sendKey: services.preferences.sendKey,
        actions: shell.messageActions,
        peekRow: (key) => session.client.store.peekRow(key),
        // One `suggest` for both lists: `@` people and `:` emoji.
        suggest: combinedSuggest(mentions.suggest, shell.emoji),
        onAccepted: (request) => void mentions.afterSend(request.entities),
        reporter: createComposeReporter({ chatId: chat.chatId, clock: browserClock(), client: session.client }),
        ...(attachments && shell.attachments ? { attachments: { model: attachments, session: shell.attachments } } : {}),
      }),
    [chat, surface, mentions, attachments],
  )
  // The emoji button beside send: a stand-in of the same size until the pickers' code is here.
  const emojiSlot = useModel(() => {
    const emoji = shell.emoji
    if (!emoji) return undefined
    return new ComposerEmojiSlot({
      emoji,
      insert: (value) => {
        composer.model.composer.insertText(value)
        composer.model.focus()
      },
    })
  }, [shell, composer])
  const find = useModel(
    () =>
      new ChatFind({
        chatId: chat.chatId,
        chunk: services.views.find,
        client: session.client,
        clock: browserClock(),
        jumpTo: (messageId) => chat.timeline.jumpToMessage(messageId, { highlight: true }),
        peekMessage: (messageId) => session.client.store.peekRow(rowKey("message", receivedMessageRowId(chat.chatId, messageId))) as
          | MessageRow
          | undefined,
        captureFocus: () => {
          const doc = surface.element()?.ownerDocument
          const before = doc?.activeElement
          return () => {
            if (before instanceof HTMLElement && before.isConnected && before !== doc?.body) before.focus({ preventScroll: true })
            else composer.model.focus()
          }
        },
      }),
    [chat, surface, composer],
  )
  useModel(() => ({ dispose: shell.registerFind(paneId, find, () => surface.element()) }), [shell, paneId, find, surface])
  // Files dragged over the pane go to this chat's attachments, also while editing (the Mac's rule).
  const drop = useModel(() => chatDropTarget(attachments), [attachments])
  const dropRef = useElement(drop)
  // The message area: the media layer's visibility hints watch the timeline's scroll container (set by
  // the time this ref runs), and the toasts sit in its inline-end, block-end corner, above the composer.
  const messageArea = useModel(
    () => (element: HTMLElement) => {
      const detachScroller = content.scroller(surface.element() ?? element)
      const detachToasts = shell.toasts.container.attach(element)
      return () => {
        detachScroller()
        if (typeof detachToasts === "function") detachToasts()
      }
    },
    [content, surface, shell],
  )
  const messageAreaRef = useElement(messageArea)
  // Hover quick actions and the context menu of this chat's rows; keyboard focus on a row
  // is the target of the message commands (Mod+E, Mod+Backspace, ...).
  const rowActions = useModel(() => {
    const controller = new MessageActionsController({ actionsFor: shell.messageActions.actionsFor })
    const actions = session.actions
    const stopFocus = effect(() => {
      const rowId = controller.focusedRowId.get()
      untracked(() => actions.setFocused(rowId ?? undefined))
    })
    // The reaction picker points at this list's rows and keeps its row active while open.
    const detachAnchors = shell.messageActions.registerPickerAnchors(chat.chatId, controller)
    return {
      controller,
      dispose: () => {
        detachAnchors()
        stopFocus()
        controller.dispose()
        if (controller.focusedRowId.peek() !== null) actions.setFocused(undefined)
      },
    }
  }, [chat])
  const spellcheck = useSignal(services.preferences.spellCheck)
  const isDM = useSignal(chat.header).isDirect
  const renderItem = useModel(
    () =>
      createRenderItem({
        store: session.client.store,
        timeZone: services.timeZone,
        isDM,
        parseAppLink: services.parseAppLink,
        openDestination: (destination) => session.workspace.open(destination),
        content,
        onReplyClick: (_rowId, messageId) => chat.timeline.jumpToMessage(messageId, { highlight: true }),
        onReactionClick: (rowId, reaction) => shell.messageActions.toggleReaction(rowId, reaction.emoji),
        actions: rowActions.controller,
        highlightRangesFor: (rowId) => find.highlights.rangesFor(rowId),
        // Reaction chips: "thumbs up, 3, including you" once the emoji table is here; "You" in tooltips.
        emojiEngine: shell.emojiEngine,
        viewerId: session.userId,
      }),
    [chat, isDM, content, rowActions, find],
  )
  const surfaceState = useSignal(shell.surface)
  const storageFull = surfaceState.kind === "banner" && surfaceState.banner === "storageFull"
  return (
    <div ref={dropRef} {...stylex.props(styles.pane)}>
      <TitleStrip leading={props.leading}>
        <ChatHeader chat={chat} onOpenInfo={() => void session.workspace.openInPane(paneId, { kind: "chatInfo", chatId: chat.chatId })} />
      </TitleStrip>
      <div ref={messageAreaRef} {...{ [FOCUS_REGION_ATTRIBUTE]: "timeline" }} {...stylex.props(styles.timeline)}>
        <MessageActionsRegion controller={rowActions.controller} style={styles.rows}>
          <TimelineView surface={surface} renderItem={renderItem} />
        </MessageActionsRegion>
        <FindLayer find={find} services={services} shell={shell} />
      </div>
      <div {...{ [FOCUS_REGION_ATTRIBUTE]: "composer" }} {...stylex.props(styles.composer)}>
        {storageFull && (
          <p role="status" {...stylex.props(styles.note)}>
            {storageFullComposerNote}
          </p>
        )}
        <ComposerView
          model={composer.model}
          spellcheck={spellcheck}
          {...(attachments ? { attachments } : {})}
          {...(emojiSlot ? { trailing: <ComposerEmojiControl slot={emojiSlot} /> } : {})}
        />
      </div>
      {attachments && <DropOverlay target={drop} />}
    </div>
  )
}

/**
 * The composer's emoji button: the emoji feature's once its pickers' code and
 * services are there, before that a stand-in with the same name and box that
 * loads them and opens the picker when it can.
 */
function ComposerEmojiControl(props: { slot: ComposerEmojiSlot }) {
  const picker = useSignal(props.slot.picker)
  const chunk = useSignal(props.slot.chunk)
  if (picker && chunk) return <chunk.ComposerEmojiButton controller={picker} style={styles.emojiButton} />
  return (
    <IconButton
      label="Emoji"
      icon={<EmojiIcon />}
      // Keep the caret in the editor when pressed with a pointer.
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => props.slot.request()}
      style={styles.emojiButton}
    />
  )
}

/** The find bar over the message area, once Mod+F loaded it for this chat. */
function FindLayer(props: { find: ChatFind; services: AppServices; shell: ShellModel }) {
  const model = useSignal(props.find.model)
  const chunk = useSignal(props.find.chunk)
  const sender = useModel(() => {
    const store = props.shell.session.client.store
    return (fromId: UserID, out: boolean): FindSender => {
      if (out) return { name: "You" }
      const user = store.peekRow(rowKey("user", fromId)) as UserRow | undefined
      if (!user) return { name: "Unknown" }
      return { name: userDisplayName(user), seed: userAvatarSeed(user), ...(user.photoUrl ? { photoUrl: user.photoUrl } : {}) }
    }
  }, [props.shell])
  if (!model || !chunk) return null
  return <chunk.FindBar model={model} platform={props.services.runtime.app.keyboard.platform} sender={sender} />
}

const styles = stylex.create({
  pane: {
    position: "relative",
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minBlockSize: 0,
    backgroundColor: color.windowBackground,
  },
  timeline: {
    // The find bar is an overlay positioned in the message area (find/README.md, "Overlay, not an inset").
    position: "relative",
    display: "flex",
    flexDirection: "column",
    flexGrow: 1,
    minBlockSize: 0,
  },
  rows: {
    display: "flex",
    flexDirection: "column",
    flexGrow: 1,
    minBlockSize: 0,
  },
  composer: {
    flexShrink: 0,
  },
  emojiButton: {
    flexShrink: 0,
    inlineSize: "28px",
    blockSize: "28px",
    marginBlock: "3px",
    borderRadius: radius.pill,
    color: color.secondaryLabel,
  },
  note: {
    margin: 0,
    paddingInline: space.xl,
    paddingBlockStart: space.sm,
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
  },
})
