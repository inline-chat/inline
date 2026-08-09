import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { InlineCoreRecoveryView } from "./InlineCoreRecoveryView"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

describe("InlineCoreRecoveryView", () => {
  it("requires an explicit reload after a terminal owner failure", () => {
    const onReload = vi.fn()
    render(<InlineCoreRecoveryView onReload={onReload} />)

    expect(screen.getByRole("alert")).toHaveTextContent(
      "Inline couldn’t continue. Please reload the app.",
    )
    fireEvent.click(
      screen.getByRole("button", { name: "Reload Inline" }),
    )
    expect(onReload).toHaveBeenCalledOnce()
  })

  it("explains the deliberate single-tab tradeoff", () => {
    const view = render(
      <InlineCoreRecoveryView failureCode="owner-unavailable" />,
    )

    expect(view.container).toHaveTextContent(
      "Inline is open in another tab. Close it, then reload this tab.",
    )
  })
})
