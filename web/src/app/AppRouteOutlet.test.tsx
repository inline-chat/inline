import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AppRouteOutlet } from "./AppRouteOutlet"

const presentation = vi.hoisted(() => ({
  targetPath: undefined as string | undefined,
}))

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  keyframes: <T,>(frames: T) => frames,
  props: () => ({}),
}))

vi.mock("@tanstack/react-router", () => ({
  Outlet: () => <button type="button">Previous message action</button>,
}))

vi.mock("./AppRoutePresentation", () => ({
  useAppRoutePresentation: () => presentation,
}))

afterEach(() => {
  cleanup()
  presentation.targetPath = undefined
})

describe("AppRouteOutlet", () => {
  it("makes stale route content inert and moves focus through presentation", () => {
    const view = render(<AppRouteOutlet />)
    screen.getByRole("button").focus()

    presentation.targetPath = "/chat/chat/20"
    view.rerender(<AppRouteOutlet />)

    const content = document.querySelector("[data-inline-route-content]")
    const status = screen.getByRole("status")
    expect(content).toHaveAttribute("inert")
    expect(content).toHaveAttribute("aria-hidden", "true")
    expect(status).toHaveAccessibleName("Loading conversation…")
    expect(status.textContent).toBe("")
    expect(status).toHaveFocus()

    presentation.targetPath = undefined
    view.rerender(<AppRouteOutlet />)

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(content).not.toHaveAttribute("inert")
    expect(content).not.toHaveAttribute("aria-hidden")
    expect(content).toHaveFocus()
  })
})
