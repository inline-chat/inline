import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { SettingsAccountView } from "./SettingsAccountView"

const mocks = vi.hoisted(() => ({ stop: vi.fn(), revoke: vi.fn(), logout: vi.fn(), navigate: vi.fn() }))
vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles, defineVars: <T,>(tokens: T) => tokens, props: () => ({}),
}))
vi.mock("@tanstack/react-router", () => ({ useNavigate: () => mocks.navigate }))
vi.mock("@inline/client", async (importOriginal) => ({
  ...await importOriginal<typeof import("@inline/client")>(), useRealtimeClient: () => ({ stop: mocks.stop }),
}))
vi.mock("~/inline/auth/auth-session", () => ({
  authSession: { logout: mocks.logout }, useAuthSession: () => ({ currentUserId: "7", token: "7:test" }),
}))
vi.mock("~/inline/auth/auth-api", () => ({ inlineAuthApi: { logout: mocks.revoke } }))
vi.mock("~/inline/data/react", () => ({ useInlineObject: () => undefined }))
vi.mock("~/ui/Avatar", () => ({ UserAvatar: () => <span>avatar</span> }))

afterEach(cleanup)
beforeEach(() => {
  vi.resetAllMocks()
  mocks.stop.mockResolvedValue(undefined)
  mocks.revoke.mockResolvedValue(undefined)
  mocks.logout.mockResolvedValue(undefined)
  mocks.navigate.mockResolvedValue(undefined)
})

describe("account logout", () => {
  it.each(["success", "transport failure", "offline"])("clears local authority with %s", async (scenario) => {
    if (scenario === "transport failure") mocks.stop.mockRejectedValue(new Error("teardown failed"))
    if (scenario === "offline") mocks.revoke.mockRejectedValue(new Error("offline"))
    render(<SettingsAccountView />)
    fireEvent.click(screen.getByRole("button", { name: "Log Out" }))
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith({ to: "/login", replace: true }))
    expect(mocks.revoke).toHaveBeenCalledWith("7:test")
    expect(mocks.logout).toHaveBeenCalledOnce()
  })

  it("does not claim completion when local credential removal fails", async () => {
    mocks.logout.mockRejectedValue(new Error("storage unavailable"))
    render(<SettingsAccountView />)
    fireEvent.click(screen.getByRole("button", { name: "Log Out" }))
    expect(await screen.findByRole("alert")).toHaveTextContent("storage unavailable")
    expect(mocks.navigate).not.toHaveBeenCalled()
  })
})
