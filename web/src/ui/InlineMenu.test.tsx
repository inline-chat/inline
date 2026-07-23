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
})
