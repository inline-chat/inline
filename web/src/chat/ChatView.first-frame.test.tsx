import {
  DbObjectKind,
  messageKey,
  type Chat,
  type Dialog,
  type Message,
} from "@inline/client"
import {
  chatId,
  dialogId,
  messageId,
  userId,
} from "@inline/ids"
import { cleanup, render, screen } from "@testing-library/react"
import { useLayoutEffect } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { PreparedChatPayload } from "./ChatOpenPreloader"
import {
  ChatView,
} from "./ChatView"
import { preparedChatMatchesRoute } from "./PreparedChatRoute"

const runtime = vi.hoisted(() => ({
  activateChat: vi.fn(() => vi.fn()),
  updateVisibleRange: vi.fn(),
  finishRoutePresentation: vi.fn(),
}))

const cachedDialog: Dialog = {
  kind: DbObjectKind.Dialog,
  id: dialogId(100),
  chatId: chatId(10),
  peerThreadId: chatId(10),
  open: true,
}
const cachedChat: Chat = {
  kind: DbObjectKind.Chat,
  id: chatId(10),
  title: "Prepared Inline thread",
}
const cachedMessage: Message = {
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(1)),
  messageId: messageId(1),
  chatId: chatId(10),
  fromId: userId(8),
  message: "Already resident",
  date: 1,
}
const peer = {
  peerKind: "chat",
  peerId: chatId(10),
} as const
const prepared: PreparedChatPayload = {
  preparationId: "prepared-chat-1",
  accountId: userId(7),
  peer,
  dialogId: dialogId(100),
  chatId: chatId(10),
  messagesInitialState: [cachedMessage],
  preparedMessageIds: [messageId(1)],
  source: "latest",
  preparedMessageCount: 1,
  needsHistoryRefresh: false,
  promotedMediaCount: 0,
  preparedAt: 1,
  performanceTraceId: "chat-open-test",
}

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => vi.fn(),
}))

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useInlineClient: () => ({
      db: {
        isMessageInHistoryWindow: () => true,
      },
      realtime: {
        mutate: vi.fn(async () => undefined),
        resendMessage: vi.fn(async () => undefined),
      },
    }),
  }
})

vi.mock("~/inline/data/react", () => ({
  useInlineObject: (kind: DbObjectKind) => {
    if (kind === DbObjectKind.Dialog) return cachedDialog
    if (kind === DbObjectKind.Chat) return cachedChat
    return undefined
  },
  useInlineQuery: (
    _key: string,
    kind: DbObjectKind,
  ) => {
    if (kind === DbObjectKind.Dialog) return []
    // A query subscription is registered after the first render. The
    // prepared payload must still supply its resident row synchronously.
    if (kind === DbObjectKind.Message) return []
    return []
  },
}))

vi.mock("~/inline/messages/InlineMessageReferencesContext", () => ({
  useInlineMessageReferences: () => new Map(),
}))

vi.mock("~/inline/runtime/InlineRuntimeContext", () => ({
  useInlineRuntimeState: () => ({
    accountId: userId(7),
    connectionState: "idle",
  }),
  useFullChatProgressive: () => runtime,
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: vi.fn() }),
}))

vi.mock("~/app/AppRoutePresentation", () => ({
  useAppRoutePresentation: () => ({
    finish: runtime.finishRoutePresentation,
  }),
}))

vi.mock("./useChatHistory", () => ({
  useChatHistory: () => ({
    initialLoading: false,
    loadingOlder: false,
    loadingNewer: false,
    hasOlder: true,
    loadOlder: vi.fn(),
    loadNewer: vi.fn(),
    loadAround: vi.fn(async () => false),
  }),
}))

vi.mock("./useChatReadState", () => ({
  useChatReadState: () => ({
    active: true,
    atBottom: true,
    needsRead: false,
    latestMessageId: undefined,
    onBottomStateChange: vi.fn(),
  }),
}))

vi.mock("./useChatOpenPaintTrace", () => ({
  useChatOpenPaintTrace: () => vi.fn(),
}))

vi.mock("./ChatToolbar", () => ({
  ChatToolbar: ({
    chatId: value,
    dialogId: valueDialogId,
  }: {
    chatId?: string
    dialogId?: string
  }) => (
    <div data-testid="toolbar">
      {value}:{valueDialogId}
    </div>
  ),
}))

vi.mock("./ChatLoadingView", () => ({
  ChatLoadingView: () => <div>Preparing chat</div>,
}))

vi.mock("./MessageListView", () => ({
  MessageListView: ({
    rows,
    loading,
    onFirstLayout,
  }: {
    rows: unknown[]
    loading: boolean
    onFirstLayout?: () => void
  }) => {
    useLayoutEffect(() => onFirstLayout?.(), [onFirstLayout])
    return (
      <div data-testid="message-list">
        rows={rows.length};loading={String(loading)}
      </div>
    )
  },
}))

vi.mock("./ComposeView", () => ({
  ComposeView: ({ chatId: value }: { chatId: bigint }) => (
    <div data-testid="compose">compose:{String(value)}</div>
  ),
}))

vi.mock("./PinnedMessageHeaderView", () => ({
  makePinnedMessageHeaderPresentation: () => ({
    label: "Pinned message unavailable",
  }),
  PinnedMessageHeaderView: () => null,
}))

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe("ChatView prepared first frame", () => {
  it("commits toolbar, resident window, and compose from one prepared identity", () => {
    const events: string[] = []
    runtime.activateChat.mockImplementation(() => {
      events.push("view lease")
      return vi.fn()
    })

    render(
      <ChatView
        peer={peer}
        prepared={prepared}
        onPreparedPresentationAdopted={() => {
          events.push("prepared lease released")
        }}
      />,
    )

    expect(screen.getByTestId("toolbar")).toHaveTextContent(
      "10:100",
    )
    expect(screen.getByTestId("message-list")).toHaveTextContent(
      "rows=1;loading=false",
    )
    expect(screen.getByTestId("compose")).toHaveTextContent(
      "compose:10",
    )
    expect(events).toEqual([
      "view lease",
      "prepared lease released",
    ])
  })

  it("rejects a prepared payload from another route or account", () => {
    expect(
      preparedChatMatchesRoute(
        prepared,
        userId(8),
        peer,
      ),
    ).toBe(false)
    expect(
      preparedChatMatchesRoute(prepared, userId(7), {
        peerKind: "chat",
        peerId: chatId(11),
      }),
    ).toBe(false)
  })
})
