import * as stylex from "@stylexjs/stylex"

export const color = stylex.defineVars({
  windowBackground: "light-dark(#ffffff, #1c1c1e)",
  sidebarBackground: "light-dark(#f4f4f5, #232326)",
  separator: "light-dark(rgb(0 0 0 / 0.09), rgb(255 255 255 / 0.1))",
  textPrimary: "light-dark(#18181b, #f4f4f5)",
  textSecondary: "light-dark(#71717a, #a1a1aa)",
})

export const size = stylex.defineVars({
  sidebarWidth: "280px",
  titleBarHeight: "44px",
})
