import * as stylex from "@stylexjs/stylex"

/**
 * Type: the macOS text styles at their AppKit point sizes (body is 13).
 * Families fall back to each platform's UI font.
 */
export const font = stylex.defineVars({
  familySystem: 'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif',
  familyMono: 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',

  sizeLargeTitle: "26px",
  sizeTitle1: "22px",
  sizeTitle2: "17px",
  sizeTitle3: "15px",
  sizeHeadline: "13px",
  sizeBody: "13px",
  sizeCallout: "12px",
  sizeSubheadline: "11px",
  sizeFootnote: "10px",
  sizeCaption: "10px",

  lineHeightTight: "1.2",
  lineHeightBody: "1.38",

  weightRegular: "400",
  weightMedium: "500",
  weightSemibold: "600",
  weightBold: "700",
})
