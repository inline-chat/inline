import * as stylex from "@stylexjs/stylex"

/**
 * Stacking inside the page. Menus, popovers, tooltips, dialogs and toasts
 * are in the top layer and need no z-index; these order what is not.
 */
export const layer = stylex.defineVars({
  base: "0",
  raised: "1",
  sticky: "10",
  resizer: "20",
  dragPreview: "100",
})
