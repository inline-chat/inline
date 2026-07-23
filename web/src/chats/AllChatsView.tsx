import {
  DbObjectKind,
  useInlineClient,
  type Chat,
  type Dialog,
  type Space,
} from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useCallback, useMemo, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { useAppSpace } from "~/app/AppSpaceContext"
import {
  dialogActivityDate,
  sortAllChatsDialogs,
} from "~/inline/data/chat-list"
import { useInlineQuery } from "~/inline/data/react"
import { colors, metrics } from "../styles/tokens.stylex"
import {
  allChatsSectionKey,
  allChatsSectionTitle,
} from "./AllChatsDate"
import {
  AllChatsItemView,
  type AllChatsRowLayout,
} from "./AllChatsItemView"
import { AllChatsSectionHeader } from "./AllChatsSectionHeader"
import { useInlineRuntimeState } from "~/inline/runtime/InlineRuntimeContext"
import { AllChatsLoadingView } from "./AllChatsLoadingView"
import { InlineMenu } from "~/ui/InlineMenu"
import { InlineIconButton } from "~/ui/InlineIconButton"
import { Icon } from "~/ui/Icon"
import { useInlineObject } from "~/inline/data/react"
import { NewThreadAction } from "~/sidebar/NewThreadAction"
import { AllChatsNewThreadRow } from "./AllChatsNewThreadRow"
import { InlineNavigationControls } from "~/ui/InlineNavigationControls"

const allChats = () => true

export function AllChatsView({
  archived,
  onArchivedChange,
}: {
  archived: boolean
  onArchivedChange: (archived: boolean) => void
}) {
  const navigate = useNavigate()
  const { selectedSpaceId } = useAppSpace()
  const { auth, realtime } = useInlineClient()
  const { cacheReady } = useInlineRuntimeState()
  const [rowLayout, setRowLayout] =
    useState<AllChatsRowLayout>("twoLine")
  const selectedSpace = useInlineObject<DbObjectKind.Space, Space>(
    DbObjectKind.Space,
    selectedSpaceId,
  )
  const predicate = useCallback(
    (dialog: Dialog) =>
      Boolean(dialog.archived) === archived &&
      !dialog.chatListHidden &&
      (selectedSpaceId == null || dialog.spaceId === selectedSpaceId),
    [archived, selectedSpaceId],
  )
  const dialogs = useInlineQuery<DbObjectKind.Dialog, Dialog>(
    `all-chats:${selectedSpaceId ?? "home"}`,
    DbObjectKind.Dialog,
    predicate,
  )
  const chats = useInlineQuery<DbObjectKind.Chat, Chat>("all-chats-metadata", DbObjectKind.Chat, allChats)
  const sections = useMemo(() => {
    const chatsById = new Map(chats.map((chat) => [chat.id, chat]))
    const result: Array<{ key: string; title: string; dialogs: Dialog[] }> = []
    for (const dialog of sortAllChatsDialogs(dialogs, chatsById)) {
      if (!chatsById.has(dialog.chatId)) continue
      const timestamp = dialogActivityDate(dialog, chatsById)
      const key = allChatsSectionKey(timestamp)
      const last = result.at(-1)
      if (last?.key === key) {
        last.dialogs.push(dialog)
      } else {
        result.push({
          key,
          title: allChatsSectionTitle(timestamp),
          dialogs: [dialog],
        })
      }
    }
    return result
  }, [chats, dialogs])
  const title = [
    archived ? "Archived" : undefined,
    selectedSpace?.name,
    "Chats",
  ].filter(Boolean).join(" ")
  const createNewThread = useCallback(async () => {
    await NewThreadAction.start({
      realtime,
      currentUserId: auth.getState().currentUserId,
      spaceId: selectedSpaceId,
      openThread: (chatId) => {
        void navigate({
          to: "/chat/$peerKind/$peerId",
          params: { peerKind: "chat", peerId: String(chatId) },
        })
      },
    })
  }, [auth, navigate, realtime, selectedSpaceId])

  return (
    <section
      data-inline-all-chats-layout={rowLayout}
      {...stylex.props(styles.root)}
    >
      <header {...stylex.props(styles.toolbar)}>
        <InlineNavigationControls />
        <h1 {...stylex.props(styles.title)}>{title}</h1>
        <span {...stylex.props(styles.toolbarActions)}>
          <InlineMenu
            align="end"
            items={[
              {
                label: "Title and Preview on One Line",
                checked: rowLayout === "titlePreviewLine",
                onSelect: () =>
                  setRowLayout((current) =>
                    current === "twoLine" ? "titlePreviewLine" : "twoLine",
                  ),
              },
            ]}
            trigger={
              <InlineIconButton aria-label="View Options" title="View Options">
                <Icon name="sliders" size={15} />
              </InlineIconButton>
            }
          />
          <InlineIconButton
            aria-label={archived ? "Show Chats" : "Show Archived Chats"}
            aria-pressed={archived}
            title={archived ? "Show Chats" : "Show Archived Chats"}
            selected={archived}
            onClick={() => onArchivedChange(!archived)}
          >
            <Icon name="archive" size={15} />
          </InlineIconButton>
        </span>
      </header>
      <div {...stylex.props(styles.list)}>
        {!cacheReady ? <AllChatsLoadingView /> : null}
        {cacheReady && !archived ? (
          <AllChatsNewThreadRow onCreate={createNewThread} />
        ) : null}
        {cacheReady
          ? sections.map((section) => (
              <section key={section.key}>
                <AllChatsSectionHeader title={section.title} />
                {section.dialogs.map((dialog) => (
                  <AllChatsItemView
                    key={dialog.id}
                    dialog={dialog}
                    layout={rowLayout}
                  />
                ))}
              </section>
            ))
          : null}
        {cacheReady && sections.length === 0 ? (
          <p {...stylex.props(styles.empty)}>
            {archived ? "No archived chats" : "No chats"}
          </p>
        ) : null}
      </div>
    </section>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    backgroundColor: colors.content,
  },
  toolbar: {
    height: metrics.toolbarHeight,
    display: "flex",
    alignItems: "center",
    paddingInline: 16,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
    flexShrink: 0,
    gap: 10,
  },
  toolbarActions: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    marginInlineStart: "auto",
  },
  title: {
    margin: 0,
    fontSize: 14,
    fontWeight: 600,
  },
  list: {
    width: "100%",
    paddingBlock: "2px 10px",
    overflowY: "auto",
  },
  empty: {
    marginTop: 60,
    color: colors.textTertiary,
    fontSize: 13,
    textAlign: "center",
  },
})
