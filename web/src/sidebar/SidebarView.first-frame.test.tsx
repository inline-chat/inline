import { DbObjectKind, type Chat, type Dialog } from "@inline/client"
import { chatId, dialogId } from "@inline/ids"
import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SidebarView } from "./SidebarView"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@tanstack/react-router", () => ({
  useLocation: () => ({ pathname: "/chats" }),
  useNavigate: () => vi.fn(),
}))

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useInlineClient: () => ({
      auth: { getState: () => ({ currentUserId: undefined }) },
      realtime: {},
    }),
  }
})

vi.mock("~/app/AppSpaceContext", () => ({
  useAppSpace: () => ({ selectedSpaceId: null }),
}))

vi.mock("~/inline/runtime/InlineRuntimeContext", () => ({
  useInlineRuntimeState: () => ({ cacheReady: true }),
}))

vi.mock("~/inline/preferences/InlineAppearancePreferencesContext", () => ({
  useInlineAppearancePreferences: () => ({
    preferences: { sidebarItemSize: "large" },
  }),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: vi.fn() }),
}))

const cachedDialog: Dialog = {
  kind: DbObjectKind.Dialog,
  id: dialogId(-44),
  chatId: chatId(44),
  peerThreadId: chatId(44),
  open: true,
}

const cachedChat: Chat = {
  kind: DbObjectKind.Chat,
  id: chatId(44),
  title: "Cached project thread",
}

vi.mock("~/inline/data/react", () => ({
  useInlineQuery: (kind: string, objectKind: DbObjectKind) =>
    objectKind === DbObjectKind.Dialog ? [cachedDialog] : [cachedChat],
}))

vi.mock("./SidebarTopBar", () => ({ SidebarTopBar: () => null }))
vi.mock("./SidebarFooter", () => ({ SidebarFooter: () => null }))
vi.mock("./SidebarActionRow", () => ({ SidebarActionRow: () => null }))
vi.mock("./SidebarNewThreadRow", () => ({ SidebarNewThreadRow: () => null }))
vi.mock("./SidebarChatItem", () => ({
  SidebarChatItem: ({ dialog }: { dialog: Dialog }) => (
    <div>Cached project thread {String(dialog.chatId)}</div>
  ),
}))

afterEach(cleanup)

describe("SidebarView cached first frame", () => {
  it("commits resident Inbox chats without an intermediate loading state", () => {
    render(<SidebarView />)

    expect(screen.getByText(/Cached project thread/)).toBeInTheDocument()
    expect(screen.queryByText("Loading chats…")).toBeNull()
  })
})
