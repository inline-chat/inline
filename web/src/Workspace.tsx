import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react"
import {
  createRootRouteWithContext,
  createRoute,
  createRouter,
  Link,
  Outlet,
  RouterProvider,
  useNavigate,
  useRouterState,
} from "@tanstack/react-router"
import { DbObjectKind, messageKey, type Dialog, type Space, type User } from "@inline/client/core"
import { parseInlineId, type ChatID, type SpaceID, type UserID } from "@inline/ids"
import type { Account } from "./core"
import { useRows, nameForUser } from "./data"
import { titleForChat } from "./conversation/projection"
import { getServerUrl } from "@inline/config"
import { AuthApi } from "./auth/api"
import { ConversationNavigation } from "./navigation"
import { ChatScreen } from "./chat/ChatScreen"
import { applyTheme, readPreference } from "./preferences"

const root = createRootRouteWithContext<{
  account: Account
  navigation: ConversationNavigation
  onSignInAgain: () => void
}>()({ component: Workspace })
const home = createRoute({
  getParentRoute: () => root,
  path: "/",
  component: Welcome,
})
export const chatRoute = createRoute({
  getParentRoute: () => root,
  path: "/chat/$chatId",
  component: ChatScreen,
  gcTime: 0,
  staleTime: 0,
  loader: ({ context, params, abortController }) =>
    context.navigation.open(params.chatId, abortController.signal),
  errorComponent: ({ error }) => (
    <div className="welcome">
      <h1>Couldn’t open this conversation</h1>
      <p role="alert">{error.message}</p>
      <Link to="/">Back to conversations</Link>
    </div>
  ),
  pendingComponent: PendingConversation,
})
const tree = root.addChildren([home, chatRoute])

export function WorkspaceRouter({
  account,
  onSignInAgain,
}: {
  account: Account
  onSignInAgain: () => void
}) {
  const [navigation] = useState(() => new ConversationNavigation(account))
  const [router] = useState(() =>
    createRouter({
      routeTree: tree,
      context: { account, navigation, onSignInAgain },
      defaultPendingMs: 150,
      defaultPreload: false,
    })
  )
  useEffect(() => {
    const detach = account.attachViewCleanup(() => navigation.close())
    return detach
  }, [account, navigation])
  return <RouterProvider router={router} />
}

export function useAccount(): Account {
  return root.useRouteContext().account
}
export function useConversationNavigation(): ConversationNavigation {
  return root.useRouteContext().navigation
}

function PendingConversation() {
  const account = useAccount()
  const snapshot = useSyncExternalStore(account.subscribe, account.getSnapshot, account.getSnapshot)
  return (
    <div className="welcome">
      <p role="status">
        {snapshot.connectionState === "connected"
          ? "Opening conversation…"
          : "Waiting for a connection to open this conversation…"}
      </p>
      <Link to="/">Back to conversations</Link>
    </div>
  )
}

function Workspace() {
  const account = useAccount()
  const { onSignInAgain } = root.useRouteContext()
  const chats = useRows(account.db, DbObjectKind.Chat)
  const dialogs = useRows(account.db, DbObjectKind.Dialog)
  const users = useRows(account.db, DbObjectKind.User)
  const spaces = useRows(account.db, DbObjectKind.Space)
  const messages = useRows(account.db, DbObjectKind.Message)
  const userMap = useMemo(() => new Map(users.map((user) => [user.id, user])), [users])
  const chatMap = useMemo(() => new Map(chats.map((chat) => [chat.id, chat])), [chats])
  const messageMap = useMemo(
    () => new Map(messages.map((message) => [message.id, message])),
    [messages]
  )
  const [space, setSpace] = useState<SpaceID | "all">("all")
  const [search, setSearch] = useState("")
  const [unreadOnly, setUnreadOnly] = useState(false)
  const [limit, setLimit] = useState(100)
  const [settings, setSettings] = useState(false)
  const [newThread, setNewThread] = useState(false)
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  })
  const selected = pathname.startsWith("/chat/")
    ? parseInlineId<"chat">(pathname.slice(6), { positive: true })
    : undefined
  const snapshot = useSyncExternalStore(account.subscribe, account.getSnapshot, account.getSnapshot)
  const searchRef = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()
  const [density, setDensity] = usePreference("inline-web-density", "standard")
  const [theme, setTheme] = usePreference("inline-web-theme", "system")
  useLayoutEffect(() => {
    applyTheme(theme)
  }, [theme])
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        searchRef.current?.focus()
      }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [])
  const visible = useMemo(
    () =>
      dialogs
        .filter((dialog) => {
          const chat = chatMap.get(dialog.chatId)
          if (!chat || dialog.archived || dialog.chatListHidden) return false
          if (space !== "all" && (dialog.spaceId ?? chat.spaceId) !== space) return false
          if (unreadOnly && !(dialog.unreadCount || dialog.unreadMark)) return false
          return chatTitle(chat, userMap).toLowerCase().includes(search.toLowerCase().trim())
        })
        .sort((a, b) => {
          if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
          if (a.order && b.order && a.order !== b.order) return a.order < b.order ? -1 : 1
          return (chatMap.get(b.chatId)?.date ?? 0) - (chatMap.get(a.chatId)?.date ?? 0)
        }),
    [dialogs, chatMap, userMap, space, unreadOnly, search]
  )
  const sections: [string, Dialog[]][] = [
    ["Pinned", visible.filter((d) => d.pinned)],
    ["Threads", visible.filter((d) => !d.pinned && !chatMap.get(d.chatId)?.peerUserId)],
    ["People", visible.filter((d) => !d.pinned && chatMap.get(d.chatId)?.peerUserId)],
  ]
  let rowCount = 0
  return (
    <div className={`workspace density-${density} ${selected ? "has-chat" : ""}`}>
      <aside className="sidebar" aria-label="Conversations">
        <header className="sidebar-header">
          <Link to="/" className="brand">
            <img src="/favicon.svg" alt="" />
            <strong>Inline</strong>
          </Link>
          <button
            className="icon-button"
            aria-label="New thread"
            title="New thread"
            onClick={() => setNewThread(true)}
          >
            <Icon name="compose" />
          </button>
        </header>
        <div className="space-picker">
          <label className="sr-only" htmlFor="space">
            Space
          </label>
          <Icon name="stack" />
          <select
            id="space"
            value={space}
            onChange={(e) => {
              setSpace(e.target.value === "all" ? "all" : (e.target.value as SpaceID))
              setLimit(100)
            }}
          >
            <option value="all">All conversations</option>
            {spaces.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
              </option>
            ))}
          </select>
        </div>
        <div className="sidebar-search">
          <Icon name="search" />
          <input
            ref={searchRef}
            aria-label="Search conversations"
            placeholder="Search"
            value={search}
            onChange={(e) => {
              setSearch(e.target.value)
              setLimit(100)
            }}
          />
          <kbd>⌘ K</kbd>
        </div>
        <button
          className={`unread-filter ${unreadOnly ? "selected" : ""}`}
          aria-pressed={unreadOnly}
          onClick={() => setUnreadOnly(!unreadOnly)}
        >
          <Icon name="inbox" />
          Unread
          <span>
            {dialogs.reduce(
              (sum, item) => sum + (item.unreadCount ?? (item.unreadMark ? 1 : 0)),
              0
            ) || ""}
          </span>
        </button>
        <nav className="conversation-list" aria-label="Threads and people">
          {sections.map(([title, rows]) =>
            rows.length ? (
              <section key={title}>
                <h2>
                  {title}
                  <span>{rows.length}</span>
                </h2>
                {rows.map((dialog) => {
                  if (++rowCount > limit) return null
                  const chat = chatMap.get(dialog.chatId)!
                  const title = chatTitle(chat, userMap)
                  const last = chat.lastMsgId
                    ? messageMap.get(messageKey(chat.id, chat.lastMsgId))
                    : undefined
                  return (
                    <Link
                      to="/chat/$chatId"
                      params={{ chatId: chat.id }}
                      key={dialog.id}
                      className={`conversation ${selected === chat.id ? "selected" : ""} ${
                        chat.parentChatId ? "nested" : ""
                      }`}
                      aria-current={selected === chat.id ? "page" : undefined}
                    >
                      <Avatar
                        title={title}
                        user={chat.peerUserId ? userMap.get(chat.peerUserId) : undefined}
                        emoji={chat.emoji}
                        thread={!chat.peerUserId}
                      />
                      <div className="conversation-label">
                        <span className="conversation-title">{title}</span>
                        {density !== "compact" && (
                          <span className="conversation-preview">
                            {chat.createState === "failed"
                              ? "Thread creation failed"
                              : chat.createState === "pending"
                              ? "Creating thread…"
                              : last?.message ||
                                (last?.media ? "Attachment" : chat.description || "")}
                          </span>
                        )}
                      </div>
                      {dialog.unreadCount || dialog.unreadMark ? (
                        <span className="badge">{dialog.unreadCount || "•"}</span>
                      ) : null}
                    </Link>
                  )
                })}
              </section>
            ) : null
          )}
          {!visible.length && (
            <p className="sidebar-empty">
              {search
                ? "No matching conversations"
                : unreadOnly
                ? "You’re all caught up"
                : "Your conversations will appear here"}
            </p>
          )}
          {visible.length > limit && (
            <button className="show-more" onClick={() => setLimit(limit + 100)}>
              Show more conversations
            </button>
          )}
        </nav>
        <footer className="sidebar-footer">
          <button
            className="account-button"
            onClick={() => setSettings(true)}
            aria-label="Open settings"
          >
            <Avatar
              title={nameForUser(userMap.get(account.accountId))}
              user={userMap.get(account.accountId)}
            />
            <span>
              <strong>{nameForUser(userMap.get(account.accountId))}</strong>
              <small>Settings</small>
            </span>
            <Icon name="settings" />
          </button>
          <div className="connection-status" role="status">
            <span className={`status-dot ${snapshot.connectionState}`} />
            {navigator.onLine === false
              ? "Offline · sends stay queued"
              : snapshot.authUnavailable
              ? "Sign-in needs attention"
              : snapshot.connectionState === "connected"
              ? "Connected"
              : snapshot.connectionState === "updating"
              ? "Updating…"
              : "Connecting…"}
            <span className="early-access">Early access</span>
          </div>
          {snapshot.error && <p className="error sidebar-error">{snapshot.error}</p>}
          {(snapshot.error || snapshot.authUnavailable) && (
            <div className="connection-actions">
              <button onClick={() => void account.retry().catch(() => undefined)}>
                Retry connection
              </button>
              {snapshot.authUnavailable && <button onClick={onSignInAgain}>Sign in again</button>}
            </div>
          )}
        </footer>
      </aside>
      <main className="main-pane">
        <Outlet />
      </main>
      {settings && (
        <Modal title="Settings" onClose={() => setSettings(false)}>
          <div className="settings-account">
            <Avatar
              title={nameForUser(userMap.get(account.accountId))}
              user={userMap.get(account.accountId)}
            />
            <strong>{nameForUser(userMap.get(account.accountId))}</strong>
          </div>
          <label className="settings-row">
            Appearance
            <select value={theme} onChange={(e) => setTheme(e.target.value)}>
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </label>
          <label className="settings-row">
            Sidebar rows
            <select value={density} onChange={(e) => setDensity(e.target.value)}>
              <option value="standard">Standard</option>
              <option value="compact">Compact</option>
            </select>
          </label>
          <p className="muted">
            Inline web · Early access
            <br />
            Text conversations, replies, and local drafts. Uploading files and calls are still in
            development.
          </p>
          <a href="https://inline.chat/download" target="_blank" rel="noreferrer">
            Get the native app ↗
          </a>
          <SignOut account={account} />
        </Modal>
      )}
      {newThread && (
        <NewThread
          account={account}
          users={users.filter(
            (user) =>
              user.id !== account.accountId &&
              dialogs.some((dialog) => dialog.peerUserId === user.id)
          )}
          spaces={spaces}
          defaultSpace={space}
          onClose={() => setNewThread(false)}
          onCreated={(id) => {
            setNewThread(false)
            void navigate({ to: "/chat/$chatId", params: { chatId: id } })
          }}
        />
      )}
    </div>
  )
}

function Welcome() {
  return (
    <div className="welcome">
      <img src="/favicon.svg" alt="" />
      <h1>Room for your work.</h1>
      <p>Pick a conversation to get started.</p>
      <div className="shortcut-tip">
        <kbd>⌘</kbd>
        <kbd>K</kbd>
        <span>Find a conversation</span>
      </div>
    </div>
  )
}

export const chatTitle = titleForChat

export function Avatar({
  title,
  user,
  emoji,
  thread = false,
}: {
  title: string
  user?: User
  emoji?: string
  thread?: boolean
}) {
  const [failed, setFailed] = useState(false)
  const url = user?.profilePhoto?.cdnUrl
  useEffect(() => setFailed(false), [url])
  return (
    <span className={`avatar ${thread ? "thread-avatar" : ""}`} aria-hidden="true">
      {url?.startsWith("https://") && !failed ? (
        <img src={url} alt="" onError={() => setFailed(true)} loading="lazy" />
      ) : (
        emoji ||
        (thread ? (
          <Icon name="hash" />
        ) : (
          title
            .split(/\s+/)
            .map((word) => word[0])
            .slice(0, 2)
            .join("")
            .toUpperCase()
        ))
      )}
    </span>
  )
}

export function Modal({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: ReactNode
}) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current!
    dialog.showModal()
    return () => dialog.close()
  }, [])
  return (
    <dialog
      className="modal"
      ref={ref}
      onCancel={onClose}
      onClick={(event) => {
        if (event.target === ref.current) onClose()
      }}
    >
      <div className="modal-content">
        <header>
          <h2>{title}</h2>
          <button className="icon-button" aria-label="Close dialog" onClick={onClose}>
            <Icon name="close" />
          </button>
        </header>
        {children}
      </div>
    </dialog>
  )
}

function NewThread({
  account,
  users,
  spaces,
  defaultSpace,
  onClose,
  onCreated,
}: {
  account: Account
  users: User[]
  spaces: Space[]
  defaultSpace: SpaceID | "all"
  onClose: () => void
  onCreated: (id: ChatID) => void
}) {
  const [title, setTitle] = useState("")
  const [selected, setSelected] = useState<UserID[]>([])
  const [space, setSpace] = useState<SpaceID | "personal">(
    defaultSpace === "all" ? "personal" : defaultSpace
  )
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  return (
    <Modal title="New thread" onClose={onClose}>
      <form
        onSubmit={(event) => {
          event.preventDefault()
          if (busy) return
          setBusy(true)
          setError("")
          void account.realtime
            .createThread({
              title: title.trim() || undefined,
              isPublic: false,
              spaceId: space === "personal" ? undefined : space,
              participants: [account.accountId, ...selected],
            })
            .then(onCreated, (reason) => {
              setBusy(false)
              setError(reason instanceof Error ? reason.message : "Could not create thread")
            })
        }}
      >
        <label htmlFor="thread-title">Thread title</label>
        <input
          id="thread-title"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="What are you working on?"
          autoFocus
          maxLength={200}
          required
        />
        <label htmlFor="thread-space">Space</label>
        <select
          id="thread-space"
          value={space}
          onChange={(e) => setSpace(e.target.value as SpaceID | "personal")}
        >
          <option value="personal">Personal</option>
          {spaces.map((item) => (
            <option key={item.id} value={item.id}>
              {item.name}
            </option>
          ))}
        </select>
        <fieldset className="people-picker">
          <legend>Invite people</legend>
          {users.length ? (
            users.map((user) => (
              <label key={user.id}>
                <input
                  type="checkbox"
                  checked={selected.includes(user.id)}
                  onChange={(e) =>
                    setSelected(
                      e.target.checked
                        ? [...selected, user.id]
                        : selected.filter((id) => id !== user.id)
                    )
                  }
                />
                <Avatar title={nameForUser(user)} user={user} />
                {nameForUser(user)}
              </label>
            ))
          ) : (
            <p className="muted">You can create a thread for yourself.</p>
          )}
        </fieldset>
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <button className="primary" disabled={busy || !title.trim()}>
          {busy ? "Creating…" : "Create thread"}
        </button>
      </form>
    </Modal>
  )
}

function usePreference(key: string, fallback: string): [string, (value: string) => void] {
  const [value, setValue] = useState(() => readPreference(key, fallback))
  return [
    value,
    (next) => {
      setValue(next)
      try {
        localStorage.setItem(key, next)
      } catch {
        /* preference remains usable for this session */
      }
    },
  ]
}

function SignOut({ account }: { account: Account }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  return (
    <div className="sign-out">
      <button
        disabled={busy}
        onClick={() => {
          setBusy(true)
          setError("")
          const token = account.auth.getToken()
          void (async () => {
            if (token)
              await new AuthApi(
                import.meta.env.DEV ? window.location.origin : getServerUrl()
              ).logout(token)
            await account.stop()
            await account.auth.logout()
          })().catch(() => {
            setBusy(false)
            setError("Could not sign out safely. Reconnect and try again.")
          })
        }}
      >
        {busy ? "Signing out…" : "Sign out"}
      </button>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </div>
  )
}

export function Icon({
  name,
}: {
  name:
    | "compose"
    | "search"
    | "stack"
    | "settings"
    | "inbox"
    | "hash"
    | "back"
    | "close"
    | "send"
    | "reply"
    | "down"
}) {
  const paths = {
    compose: "M15 3l6 6M5 19l4-1L21 6a2.1 2.1 0 0 0-3-3L6 15l-1 4M12 4H4v16h16v-8",
    search: "M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0",
    stack: "M3 7l9-5 9 5-9 5-9-5M3 12l9 5 9-5M3 17l9 5 9-5",
    settings:
      "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1 1-3",
    inbox: "M3 3h18v18H3V3M3 14h5l2 3h4l2-3h5",
    hash: "M9 3L7 21M17 3l-2 18M3 9h18M2 15h18",
    back: "M15 4l-8 8 8 8",
    close: "M6 6l12 12M18 6L6 18",
    send: "M12 20V4M5 11l7-7 7 7",
    reply: "M9 5l-6 6 6 6M3 11h11c4 0 7 3 7 7",
    down: "M5 9l7 7 7-7",
  }
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name]} />
    </svg>
  )
}
