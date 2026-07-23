import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SidebarNewThreadRow } from "./SidebarNewThreadRow"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

afterEach(cleanup)

describe("SidebarNewThreadRow", () => {
  it("uses Inline macOS naming and prevents duplicate creation", async () => {
    let finish!: () => void
    const onCreate = vi.fn(
      () => new Promise<void>((resolve) => {
        finish = resolve
      }),
    )
    render(<SidebarNewThreadRow onCreate={onCreate} />)

    const button = screen.getByRole("button", {
      name: "New Thread",
    })
    expect(button).toHaveAttribute("title", "New Thread")
    expect(screen.getByText("New thread")).toBeInTheDocument()

    fireEvent.click(button)
    fireEvent.click(button)
    expect(onCreate).toHaveBeenCalledOnce()
    expect(button).toBeDisabled()
    expect(button).toHaveAttribute("aria-busy", "true")
    expect(screen.getByText("Creating thread…")).toBeInTheDocument()

    finish()
    await waitFor(() => expect(button).not.toBeDisabled())
    expect(screen.getByText("New thread")).toBeInTheDocument()
  })

  it("keeps a real creation failure visible and allows retry", async () => {
    const onCreate = vi
      .fn<() => Promise<void>>()
      .mockRejectedValueOnce(new Error("Failed to create thread."))
      .mockResolvedValueOnce(undefined)
    render(<SidebarNewThreadRow onCreate={onCreate} />)

    fireEvent.click(screen.getByRole("button", { name: "New Thread" }))
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Failed to create thread.",
    )

    fireEvent.click(screen.getByRole("button", { name: "New Thread" }))
    await waitFor(() => expect(onCreate).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole("alert")).toBeNull()
  })
})
