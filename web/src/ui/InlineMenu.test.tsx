import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InlineMenu } from "./InlineMenu"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

afterEach(cleanup)

describe("InlineMenu", () => {
  it("exposes checked choices as real menu item checkboxes", async () => {
    const select = vi.fn()
    render(
      <InlineMenu
        trigger={<button type="button">View Options</button>}
        items={[
          {
            label: "Compact Sidebar Items",
            checked: true,
            onSelect: select,
          },
        ]}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "View Options" }))
    const choice = await screen.findByRole("menuitemcheckbox", {
      name: "Compact Sidebar Items",
    })
    expect(choice).toHaveAttribute("aria-checked", "true")
    fireEvent.click(choice)
    expect(select).toHaveBeenCalledOnce()
  })

  it("resolves Home and End against mounted items during a cold open", async () => {
    render(
      <InlineMenu
        trigger={<button type="button">More</button>}
        items={[
          { label: "Copy Link", onSelect: vi.fn() },
          { label: "Pin", onSelect: vi.fn() },
          { label: "Mark Unread", onSelect: vi.fn() },
        ]}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "More" }))
    const first = await screen.findByRole("menuitem", {
      name: "Copy Link",
    })
    const last = screen.getByRole("menuitem", {
      name: "Mark Unread",
    })

    first.focus()
    fireEvent.keyDown(first, { key: "End" })
    expect(last).toHaveFocus()

    fireEvent.keyDown(last, { key: "Home" })
    expect(first).toHaveFocus()
  })
})
