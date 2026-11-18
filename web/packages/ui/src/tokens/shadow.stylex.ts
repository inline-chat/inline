import * as stylex from "@stylexjs/stylex"

/** Elevation. The first ring is the 0.5px outline macOS draws around menus and popovers. */
export const shadow = stylex.defineVars({
  control: "0 0 0 0.5px light-dark(rgb(0 0 0 / 0.12), rgb(255 255 255 / 0.1)), 0 0.5px 1px light-dark(rgb(0 0 0 / 0.1), rgb(0 0 0 / 0.3))",
  menu: "0 0 0 0.5px light-dark(rgb(0 0 0 / 0.14), rgb(255 255 255 / 0.14)), 0 8px 24px light-dark(rgb(0 0 0 / 0.16), rgb(0 0 0 / 0.5))",
  popover: "0 0 0 0.5px light-dark(rgb(0 0 0 / 0.12), rgb(255 255 255 / 0.12)), 0 12px 32px light-dark(rgb(0 0 0 / 0.14), rgb(0 0 0 / 0.5))",
  dialog: "0 0 0 0.5px light-dark(rgb(0 0 0 / 0.1), rgb(255 255 255 / 0.12)), 0 24px 64px light-dark(rgb(0 0 0 / 0.22), rgb(0 0 0 / 0.6))",
  toast: "0 0 0 0.5px light-dark(rgb(0 0 0 / 0.1), rgb(255 255 255 / 0.12)), 0 6px 20px light-dark(rgb(0 0 0 / 0.14), rgb(0 0 0 / 0.45))",
})
