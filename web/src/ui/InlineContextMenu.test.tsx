import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InlineContextMenu } from "./InlineContextMenu"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

afterEach(cleanup)

describe("InlineContextMenu", () => {
  it("opens at a native context-menu event and dispatches an action", async () => {
    const select = vi.fn()
    render(
      <InlineContextMenu items={[{ label: "Pin", onSelect: select }]}>
        Target
      </InlineContextMenu>,
    )

    fireEvent.contextMenu(screen.getByText("Target"))
    const pin = await screen.findByRole("menuitem", { name: "Pin" })
    fireEvent.click(pin)
    expect(select).toHaveBeenCalledOnce()
  })

  it("opens from the standard keyboard context-menu shortcut", async () => {
    const select = vi.fn()
    render(
      <InlineContextMenu items={[{ label: "Mark Unread", onSelect: select }]}>
        <button type="button">Keyboard target</button>
      </InlineContextMenu>,
    )

    const target = screen.getByRole("button", { name: "Keyboard target" })
    target.focus()
    fireEvent.keyDown(target, { key: "F10", shiftKey: true })
    const action = await screen.findByRole("menuitem", {
      name: "Mark Unread",
    })
    await waitFor(() => expect(action).toHaveFocus())
    fireEvent.keyDown(action, { key: "Enter" })
    expect(select).toHaveBeenCalledOnce()
  })
})
