import { fileURLToPath } from "node:url"
import { describe, expect, test } from "vitest"
import { PHYSICAL_PROPERTIES, readStylexStyles } from "../theme/stylex-source"

const overlays = readStylexStyles(fileURLToPath(new URL("./Overlays.tsx", import.meta.url)))

const physicalKeys = (style: Record<string, unknown> | undefined) =>
  Object.keys(style ?? {}).filter((key) => PHYSICAL_PROPERTIES.includes(key))

describe("dialog and sheet layout rules", () => {
  test("a dialog is centered by margin auto, which the shared layer reset removes", () => {
    expect(overlays.dialog?.margin).toBe("auto")
  })

  test("a sheet keeps margin auto on the other sides and sits at the top", () => {
    expect(overlays.sheetPlacement?.marginBlockStart).toBe(0)
    expect(Object.keys(overlays.sheetPlacement ?? {})).toEqual(["marginBlockStart"])
  })

  test("never wider or taller than the viewport, with a gutter at narrow widths", () => {
    expect(overlays.dialog?.inlineSize).toBe("min(480px, calc(100vw - 32px))")
    expect(overlays.dialog?.maxBlockSize).toBe("calc(100dvh - 32px)")
    // The surface holds the same bound, so long content scrolls inside it rather than growing the dialog.
    expect(overlays.surface?.maxBlockSize).toBe(overlays.dialog?.maxBlockSize)
    expect(overlays.surface?.display).toBe("flex")
    expect(overlays.surface?.flexDirection).toBe("column")
  })

  test("long content scrolls in the body; the header and footer stay", () => {
    expect(overlays.body?.overflowY).toBe("auto")
    expect(overlays.body?.minBlockSize).toBe(0)
    expect(overlays.body?.flexShrink).toBe(1)
    expect(overlays.header?.flexShrink).toBe(0)
    expect(overlays.footer?.flexShrink).toBe(0)
    expect(overlays.description?.flexShrink).toBe(0)
  })

  test("logical properties only", () => {
    for (const name of ["dialog", "sheetPlacement", "surface", "sheetSurface", "header", "title", "description", "body", "footer"]) {
      expect(physicalKeys(overlays[name]), name).toEqual([])
    }
  })
})

const controls = readStylexStyles(fileURLToPath(new URL("./Controls.tsx", import.meta.url)))

describe("toast layout rules", () => {
  test("the region sits where the queue places it, with the window corner as the fallback", () => {
    expect(controls.region?.position).toBe("fixed")
    expect(controls.region?.insetInlineEnd).toBe("var(--ui-toast-inset-inline-end, 16px)")
    expect(controls.region?.insetBlockEnd).toBe("var(--ui-toast-inset-block-end, 16px)")
    expect(controls.toast?.inlineSize).toBe("min(360px, var(--ui-toast-max-inline-size, calc(100vw - 32px)))")
  })

  test("a long title or description wraps inside the toast; the buttons keep their size", () => {
    expect(controls.toastText?.minInlineSize).toBe(0)
    expect(controls.toastDescription?.overflowWrap).toBe("anywhere")
    expect(controls.toastTitle?.overflowWrap).toBe("anywhere")
    expect(controls.toastAction?.flexShrink).toBe(0)
    expect(controls.toastClose?.flexShrink).toBe(0)
  })

  test("logical properties only", () => {
    for (const name of ["region", "toastList", "toast", "toastText", "toastTitle", "toastDescription", "toastClose"]) {
      expect(physicalKeys(controls[name]), name).toEqual([])
    }
  })
})
