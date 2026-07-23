import { DbObjectKind, type User } from "@inline/client"
import { userId } from "@inline/ids"
import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SettingsView } from "./SettingsView"

let cachedUser: User | undefined

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@tanstack/react-router", () => ({ useNavigate: () => vi.fn() }))

vi.mock("~/app/AppRoutePresentation", () => ({
  useAppRoutePresentationReady: vi.fn(),
}))

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useRealtimeClient: () => ({ stop: vi.fn() }),
  }
})

vi.mock("~/inline/auth/auth-session", () => ({
  authSession: { logout: vi.fn() },
  useAuthSession: () => ({ currentUserId: userId(7) }),
}))

vi.mock("~/inline/data/react", () => ({
  useInlineObject: () => cachedUser,
}))

vi.mock("~/ui/Avatar", () => ({ UserAvatar: () => <span>avatar</span> }))

afterEach(() => {
  cachedUser = undefined
  cleanup()
})

describe("SettingsView cached first frame", () => {
  it("commits the resident Inline account without a placeholder frame", () => {
    cachedUser = {
      kind: DbObjectKind.User,
      id: userId(7),
      firstName: "Dena",
      lastName: "Inline",
      email: "dena@inline.test",
    }

    render(<SettingsView />)

    expect(screen.getByText("Dena Inline")).toBeInTheDocument()
    expect(screen.getByText("dena@inline.test")).toBeInTheDocument()
    expect(screen.queryByLabelText("Loading account")).toBeNull()
  })

  it("uses a stable account skeleton when no cached user exists", () => {
    render(<SettingsView />)

    expect(screen.getByLabelText("Loading account")).toBeInTheDocument()
    expect(screen.queryByText("Inline account")).toBeNull()
  })
})
