import {
  AuthStore,
  applyUpdates,
  Db,
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
  type RealtimeService,
  type Transaction,
} from "@inline/client/core"
import { InlineClientProvider } from "@inline/client/react"
import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { useCallback, useLayoutEffect, useRef, useState } from "react"
import { createRoot } from "react-dom/client"
import { flushSync } from "react-dom"
import { MessageListView } from "../../chat/MessageListView"
import type { MessageListViewHandle } from "../../chat/MessageListView"
import {
  InlineAppearancePreferencesProvider,
  useInlineAppearancePreferences,
} from "../../inline/preferences/InlineAppearancePreferencesContext"
import type { InlineMessageStyle } from "../../inline/preferences/InlineAppearancePreferences"
import { makeChatMessageRows } from "../../chat/ChatRowListModel"
import { messageListScrollStates } from "../../chat/MessageListScrollState"
import { ComposeView } from "../../chat/ComposeView"
import { chatOpenPerformance } from "../../chat/ChatOpenPerformance"
import { useChatOpenPaintTrace } from "../../chat/useChatOpenPaintTrace"
import { InlineMessageDrafts } from "../../inline/drafts/InlineMessageDrafts"
import { InlineMessageDraftsProvider } from "../../inline/drafts/InlineMessageDraftsContext"
import { InlineMediaLoader } from "../../inline/media/InlineMediaLoader"
import { InlineMediaProvider } from "../../inline/media/InlineMediaContext"
import { InlineMediaRepository } from "../../inline/media/InlineMediaRepository"
import type { InlineMediaCache } from "../../inline/media/cache/InlineMediaCache"
import { InlineToastProvider } from "../../ui/InlineToast"
import { RouterContextProvider } from "@tanstack/react-router"
import { getRouter } from "../../router"

const harnessRouter = getRouter()

export type MessageListBrowserMetrics = {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
  distanceToBottom: number
}

export type MessageListBrowserAnchor = {
  messageId: string
  top: number
}

export type MessageListBrowserHarness = {
  metrics: () => MessageListBrowserMetrics
  visibleAnchor: () => MessageListBrowserAnchor | undefined
  scrollToRatio: (ratio: number) => Promise<void>
  prepend: (count: number) => void
  trimStart: (count: number) => void
  trimEnd: (count: number) => void
  slideForward: (count: number) => void
  replaceWithSending: () => string
  failLast: () => void
  clickResend: () => void
  resendCount: () => number
  append: (out: boolean) => void
  appendPhoto: (out: boolean) => string
  navigateAwayAndBack: () => void
  replaceWithShortAndRemount: () => void
  firstLayoutCount: () => number
  mediaLoadCount: () => number
  applyPreviewAttachment: (messageId: string) => void
  expand: (messageId: string) => void
  expandLast: () => void
  jumpTo: (messageId: string) => boolean
  rowGeometry: (messageId: string) => { top: number; bottom: number; height: number; viewportMiddle: number } | undefined
  composerClearance: () => number
  composeText: () => string
  sendCompose: (text: string) => Promise<void>
  chatOpenTrace: () => ReturnType<typeof chatOpenPerformance.get>
  bottomState: () => boolean | undefined
  forwardOpenCount: () => number
  reactionMutationCount: () => number
  resize: (height: number) => void
  setMessageStyle: (style: InlineMessageStyle) => void
  unmount: () => void
}

const photoDataUrl =
  "data:image/svg+xml," +
  encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600"><rect width="800" height="600" fill="#8f74ee"/></svg>')

const makePhotoMessage = (id: number, out = false): Message => ({
  ...makeMessage(id, out),
  message: undefined,
  media: {
    media: {
      oneofKind: "photo",
      photo: {
        photo: {
          id: BigInt(id),
          date: 1n,
          format: 1,
          sizes: [
            {
              type: "d",
              w: 800,
              h: 600,
              size: 40_000,
              cdnUrl: photoDataUrl,
            },
            {
              type: "s",
              w: 40,
              h: 30,
              size: 3,
              bytes: new Uint8Array([1, 30, 40]),
            },
          ],
        },
      },
    },
  },
})

const targetChatId = chatId(10)

const makeMessage = (
  id: number,
  out = false,
  expanded = false,
): Message => {
  const voice = id % 23 === 0
  return {
    kind: DbObjectKind.Message,
    id: messageKey(targetChatId, messageId(id)),
    messageId: messageId(id),
    chatId: targetChatId,
    fromId: userId(out ? 7 : 8),
    out,
    date: 1_700_000_000 + id,
    message: id === 1_193
      ? undefined
      : voice
      ? undefined
      : expanded
        ? `Expanded message ${id} `.repeat(80)
        : id % 11 === 0
          ? `A naturally taller Inline message ${id} `.repeat(12)
          : `Inline message ${id}`,
    replyToMsgId: id === 1_199 ? messageId(1_190) : undefined,
    fwdFrom:
      id === 1_195
        ? {
            fromPeerId: {
              type: {
                oneofKind: "user",
                user: { userId: 8n },
              },
            },
            fromId: 8n,
            fromMessageId: 1_180n,
          }
        : undefined,
    reactions:
      id === 1_194
        ? {
            reactions: [
              {
                emoji: "👍",
                userId: 8n,
                messageId: 1_194n,
                chatId: 10n,
                date: 1_700_001_194n,
              },
              {
                emoji: "👍",
                userId: 9n,
                messageId: 1_194n,
                chatId: 10n,
                date: 1_700_001_195n,
              },
            ],
          }
        : undefined,
    replies:
      id === 1_198
        ? {
            chatId: 90n,
            replyCount: 3,
            hasUnread: true,
            recentReplierUserIds: [8n, 9n],
          }
        : undefined,
    attachments:
      id === 1_196
        ? {
            attachments: [
              {
                id: 1_196n,
                attachment: {
                  oneofKind: "urlPreview",
                  urlPreview: {
                    id: 1_196n,
                    url: "https://inline.chat",
                    siteName: "Inline",
                    title: "Inline for work",
                    description: "Fast, focused team communication",
                    photo: {
                      id: 9_196n,
                      date: 1n,
                      format: 1,
                      sizes: [
                        {
                          type: "b",
                          w: 140,
                          h: 140,
                          size: 2_000,
                          cdnUrl: photoDataUrl,
                        },
                      ],
                    },
                  },
                },
              },
            ],
          }
        : id === 1_197
          ? {
              attachments: [
                {
                  id: 1_197n,
                  attachment: {
                    oneofKind: "externalTask",
                    externalTask: {
                      id: 1_197n,
                      taskId: "ENG-42",
                      application: "linear",
                      title: "Fix message list",
                      status: 3,
                      assignedUserId: 8n,
                      url: "https://linear.app/issue/ENG-42",
                      number: "ENG-42",
                      date: 1n,
                    },
                  },
                },
              ],
            }
          : undefined,
    media: voice
      ? {
          media: {
            oneofKind: "voice",
            voice: {},
          },
        }
      : undefined,
  }
}

const viewport = (root: HTMLElement) => {
  const element = root.querySelector<HTMLElement>(
    '[data-inline-message-list="viewport"]',
  )
  if (!element) throw new Error("Message-list viewport is unavailable")
  return element
}

function Harness({
  root,
  onReady,
}: {
  root: HTMLElement
  onReady: (
    controller: Omit<
      MessageListBrowserHarness,
      "unmount" | "reactionMutationCount" | "mediaLoadCount"
    >,
  ) => void
}) {
  const appearance = useInlineAppearancePreferences()
  const [messages, setMessages] = useState(() =>
    Array.from({ length: 200 }, (_, index) =>
      makeMessage(1_000 + index, index % 4 === 0),
    ),
  )
  const [chatVisible, setChatVisible] = useState(true)
  const messagesRef = useRef(messages)
  messagesRef.current = messages
  const rows = makeChatMessageRows(
    messages,
    new Map(messages.map((message) => [message.messageId, message])),
  )
  const list = useRef<MessageListViewHandle>(null)
  const bottomState = useRef<boolean | undefined>(undefined)
  const firstLayoutCount = useRef(0)
  const forwardOpenCount = useRef(0)
  const resendCount = useRef(0)
  const [performanceTraceId] = useState(() => {
    const id = chatOpenPerformance.begin({
      peerKind: "user",
      peerId: userId(8),
    })
    chatOpenPerformance.markCacheReady(id)
    chatOpenPerformance.markProjectionReady(id, {
      source: "latest",
      preparedMessageCount: messages.length,
      promotedMediaCount: 0,
    })
    return id
  })
  const traceFirstLayout = useChatOpenPaintTrace(
    performanceTraceId,
    rows.length,
  )
  const onFirstLayout = useCallback(() => {
    firstLayoutCount.current += 1
    traceFirstLayout()
  }, [traceFirstLayout])

  useLayoutEffect(() => {
    onReady({
      metrics: () => {
        const element = viewport(root)
        return {
          scrollTop: element.scrollTop,
          scrollHeight: element.scrollHeight,
          clientHeight: element.clientHeight,
          distanceToBottom:
            element.scrollHeight -
            element.scrollTop -
            element.clientHeight,
        }
      },
      setMessageStyle: (style) => {
        appearance.update({ messageStyle: style })
      },
      visibleAnchor: () => {
        const element = viewport(root)
        const viewportRect = element.getBoundingClientRect()
        let partial: MessageListBrowserAnchor | undefined
        for (const row of element.querySelectorAll<HTMLElement>(
          "[data-message-id]",
        )) {
          const rect = row.getBoundingClientRect()
          if (
            rect.bottom > viewportRect.top &&
            rect.top < viewportRect.bottom
          ) {
            const anchor = {
              messageId: row.dataset.messageId!,
              top: rect.top - viewportRect.top,
            }
            if (rect.top >= viewportRect.top) return anchor
            partial ??= anchor
          }
        }
        return partial
      },
      scrollToRatio: async (ratio) => {
        const element = viewport(root)
        if (ratio >= 1) {
          list.current?.scrollToBottom()
          await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
          return
        }
        element.dispatchEvent(
          new WheelEvent("wheel", {
            bubbles: true,
            deltaY: ratio < 1 ? -1 : 1,
          }),
        )
        const nextFrame = () =>
          new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
        const target =
          Math.max(0, element.scrollHeight - element.clientHeight) * ratio
        for (let step = 0; step < 40; step += 1) {
          const distance = target - element.scrollTop
          if (Math.abs(distance) <= 1) break
          element.scrollTop +=
            Math.sign(distance) *
            Math.min(Math.abs(distance), element.clientHeight * 0.75)
          await nextFrame()
        }
      },
      prepend: (count) => {
        flushSync(() => {
          setMessages((current) => {
            const firstId = Number(current[0]?.messageId ?? 1_000)
            return [
              ...Array.from({ length: count }, (_, index) =>
                makeMessage(firstId - count + index),
              ),
              ...current,
            ]
          })
        })
      },
      trimStart: (count) => {
        flushSync(() => {
          setMessages((current) => current.slice(count))
        })
      },
      trimEnd: (count) => {
        flushSync(() => {
          setMessages((current) =>
            current.slice(0, Math.max(0, current.length - count)),
          )
        })
      },
      slideForward: (count) => {
        flushSync(() => {
          setMessages((current) => {
            const retained = current.slice(count)
            const lastId = Number(
              current.at(-1)?.messageId ?? 1_000,
            )
            return [
              ...retained,
              ...Array.from({ length: count }, (_, index) =>
                makeMessage(lastId + index + 1),
              ),
            ]
          })
        })
      },
      replaceWithSending: () => {
        const id = -Math.max(
          1,
          Number(
            messagesRef.current.at(-1)?.messageId ?? 1_000,
          ) + 1,
        )
        flushSync(() => {
          setMessages([
            {
              ...makeMessage(id, true),
              status: MessageSendingStatus.Sending,
            },
          ])
        })
        return String(id)
      },
      failLast: () => {
        flushSync(() => {
          setMessages((current) =>
            current.map((message, index) =>
              index === current.length - 1
                ? {
                    ...message,
                    status: MessageSendingStatus.Failed,
                  }
                : message,
            ),
          )
        })
      },
      clickResend: () => {
        const action = root.querySelector<HTMLButtonElement>(
          'button[aria-label="Resend message"]',
        )
        if (!action) throw new Error("resend action is unavailable")
        action.click()
      },
      resendCount: () => resendCount.current,
      append: (out) => {
        flushSync(() => {
          setMessages((current) => [
            ...current,
            makeMessage(
              Number(current.at(-1)?.messageId ?? 1_000) + 1,
              out,
            ),
          ])
        })
      },
      appendPhoto: (out) => {
        const id = Number(messagesRef.current.at(-1)?.messageId ?? 1_000) + 1
        flushSync(() => {
          setMessages((current) => [
            ...current,
            makePhotoMessage(Number(current.at(-1)?.messageId ?? 1_000) + 1, out),
          ])
        })
        return String(id)
      },
      navigateAwayAndBack: () => {
        flushSync(() => setChatVisible(false))
        flushSync(() => setChatVisible(true))
      },
      replaceWithShortAndRemount: () => {
        flushSync(() => setMessages(messagesRef.current.slice(-5)))
        flushSync(() => setChatVisible(false))
        flushSync(() => setChatVisible(true))
      },
      firstLayoutCount: () => firstLayoutCount.current,
      applyPreviewAttachment: (targetMessageId) => {
        const current = messagesRef.current.find(
          (message) => message.messageId === targetMessageId,
        )
        if (!current) {
          throw new Error(
            `Attachment target ${targetMessageId} is unavailable`,
          )
        }
        const ownerDb = new Db({
          autoHydrate: false,
          persistence: false,
        })
        ownerDb.insert(current)
        const report = applyUpdates(ownerDb, [
          Update.create({
            update: {
              oneofKind: "messageAttachment",
              messageAttachment: {
                chatId: BigInt(current.chatId),
                messageId: BigInt(current.messageId),
                attachment: {
                  id: 7_193n,
                  attachment: {
                    oneofKind: "urlPreview",
                    urlPreview: {
                      id: 8_193n,
                      url: "https://inline.chat/updates",
                      siteName: "Inline",
                      title: "Late Inline preview",
                      description: "Delivered after the base message",
                    },
                  },
                },
              },
            },
          }),
        ])
        if (report.applied !== 1 || report.deferred !== 0) {
          throw new Error(
            `Attachment update was not applied: ${JSON.stringify(report)}`,
          )
        }
        const updated = ownerDb.get(
          ownerDb.ref(DbObjectKind.Message, current.id),
        )
        if (!updated) throw new Error("Updated attachment message is missing")
        flushSync(() => {
          setMessages((messages) =>
            messages.map((message) =>
              message.id === updated.id ? updated : message,
            ),
          )
        })
      },
      expand: (targetMessageId) => {
        flushSync(() => {
          setMessages((current) =>
            current.map((message) =>
              message.messageId === targetMessageId
                ? makeMessage(
                    Number(message.messageId),
                    message.out,
                    true,
                  )
                : message,
            ),
          )
        })
      },
      expandLast: () => {
        flushSync(() => {
          setMessages((current) =>
            current.map((message, index) =>
              index === current.length - 1
                ? makeMessage(Number(message.messageId), message.out, true)
                : message,
            ),
          )
        })
      },
      resize: (height) => {
        root.style.height = `${height}px`
      },
      jumpTo: (messageId) => list.current?.scrollToMessage(messageId) ?? false,
      rowGeometry: (messageId) => {
        const element = viewport(root)
        const row = Array.from(element.querySelectorAll<HTMLElement>("[data-message-id]"))
          .find((candidate) => candidate.dataset.messageId === messageId)
        if (!row) return undefined
        const viewportRect = element.getBoundingClientRect()
        const rowRect = row.getBoundingClientRect()
        return {
          top: rowRect.top - viewportRect.top,
          bottom: rowRect.bottom - viewportRect.top,
          height: rowRect.height,
          viewportMiddle: viewportRect.height / 2,
        }
      },
      composerClearance: () => {
        const element = viewport(root)
        const composer = root.querySelector<HTMLElement>("[data-inline-compose]")
        if (!composer) throw new Error("compose view is unavailable")
        return composer.getBoundingClientRect().top - element.getBoundingClientRect().bottom
      },
      composeText: () =>
        root.querySelector<HTMLTextAreaElement>(
          'textarea[aria-label="Message"]',
        )?.value ?? "",
      sendCompose: async (text) => {
        const input = root.querySelector<HTMLTextAreaElement>(
          'textarea[aria-label="Message"]',
        )
        if (!input) throw new Error("compose input is unavailable")
        const setValue = Object.getOwnPropertyDescriptor(
          HTMLTextAreaElement.prototype,
          "value",
        )?.set
        setValue?.call(input, text)
        input.dispatchEvent(
          new InputEvent("input", {
            bubbles: true,
            inputType: "insertText",
            data: text,
          }),
        )
        await new Promise<void>((resolve) =>
          requestAnimationFrame(() => resolve()),
        )
        input.form?.requestSubmit()
      },
      chatOpenTrace: () => chatOpenPerformance.get(performanceTraceId),
      bottomState: () => bottomState.current,
      forwardOpenCount: () => forwardOpenCount.current,
    })
  }, [onReady, root])

  return (
    <div style={{ width: "100%", height: "100%", minHeight: 0, display: "flex", flexDirection: "column" }}>
      <div style={{ minHeight: 0, flex: 1, overflow: "hidden" }}>
        {chatVisible ? (
        <MessageListView
          key="browser-message-list-chat"
          ref={list}
          rows={rows}
          loading={false}
          loadingOlder={false}
          loadingNewer={false}
          hasOlder={false}
          hasNewer={false}
          showParticipants={false}
          scrollStateKey="browser-message-list-harness"
          onLoadOlder={() => undefined}
          onLoadNewer={() => undefined}
          onFirstLayout={onFirstLayout}
          onBottomStateChange={(value) => {
            bottomState.current = value
          }}
          unreadAfterMessageId={messageId(1_150)}
          onOpenMessage={() => {
            forwardOpenCount.current += 1
          }}
          onOpenReplyThread={() => undefined}
          onReplyMessage={() => undefined}
          onTogglePinMessage={() => undefined}
          onResendMessage={(messageId) => {
            resendCount.current += 1
            setMessages((current) =>
              current.map((message) =>
                message.messageId === messageId
                  ? {
                      ...message,
                      status: MessageSendingStatus.Sending,
                    }
                  : message,
              ),
            )
          }}
          peer={{ peerKind: "user", peerId: userId(8) }}
          currentUserId={userId(7)}
        />
        ) : (
          <div data-inline-other-chat style={{ width: "100%", height: "100%" }} />
        )}
      </div>
      <div data-inline-compose>
        <ComposeView
          peer={{ peerKind: "user", peerId: userId(8) }}
          chatId={targetChatId}
          recipientName="Dena"
        />
      </div>
    </div>
  )
}

export async function mountMessageListBrowserHarness(
  root: HTMLElement,
  options: { resetScrollState?: boolean } = {},
): Promise<MessageListBrowserHarness> {
  if (options.resetScrollState !== false) {
    messageListScrollStates.delete("browser-message-list-harness")
  }
  chatOpenPerformance.clear()
  root.replaceChildren()
  Object.assign(root.style, {
    width: "640px",
    height: "480px",
    overflow: "hidden",
  })
  const db = new Db({ autoHydrate: false, persistence: false })
  db.insert({
    kind: DbObjectKind.User,
    id: userId(8),
    firstName: "Dena",
  })
  db.insert({
    kind: DbObjectKind.User,
    id: userId(9),
    firstName: "Mo",
  })
  db.insert({
    kind: DbObjectKind.Chat,
    id: chatId(90),
    title: "Reply thread",
  })
  const auth = new AuthStore({ persistence: "memory" })
  auth.login({ token: "browser-harness", userId: userId(7) })
  let reactionMutationCount = 0
  let mediaLoadCount = 0
  const mediaBytes = new Map<string, Blob>()
  const mediaCache: InlineMediaCache = {
    get: async (key) => mediaBytes.get(key),
    put: async (key, blob) => {
      mediaBytes.set(key, blob)
    },
  }
  const mediaLoader = new InlineMediaLoader({
    cache: mediaCache,
    fetcher: async (input, init) => {
      mediaLoadCount += 1
      return fetch(input, init)
    },
  })
  const mediaRepository = new InlineMediaRepository(mediaLoader)
  const client = {
    db,
    auth,
    realtime: {
      mutate: async (transaction: Transaction) => {
        reactionMutationCount += 1
        db.batch(() => {
          transaction.optimistic?.(db, auth)
        })
        return undefined
      },
      resendMessage: async () => undefined,
    } as unknown as RealtimeService,
  }
  const drafts = new InlineMessageDrafts(db)
  const reactRoot = createRoot(root)
  const controller = await new Promise<
    Omit<
      MessageListBrowserHarness,
      "unmount" | "reactionMutationCount" | "mediaLoadCount"
    >
  >((resolve) => {
    flushSync(() => {
      reactRoot.render(
        <InlineAppearancePreferencesProvider>
          <RouterContextProvider router={harnessRouter}>
            <InlineToastProvider>
              <InlineClientProvider value={client}>
                <InlineMediaProvider repository={mediaRepository}>
                  <InlineMessageDraftsProvider drafts={drafts}>
                    <Harness root={root} onReady={resolve} />
                  </InlineMessageDraftsProvider>
                </InlineMediaProvider>
              </InlineClientProvider>
            </InlineToastProvider>
          </RouterContextProvider>
        </InlineAppearancePreferencesProvider>,
      )
    })
  })
  return {
    ...controller,
    mediaLoadCount: () => mediaLoadCount,
    reactionMutationCount: () => reactionMutationCount,
    unmount: () => {
      flushSync(() => reactRoot.unmount())
    },
  }
}
