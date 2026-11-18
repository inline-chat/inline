import * as stylex from "@stylexjs/stylex"

/** Motion is short, and off under reduced motion: every duration drops to 0ms. */
export const motion = stylex.defineVars({
  durationFast: { default: "100ms", "@media (prefers-reduced-motion: reduce)": "0ms" },
  durationNormal: { default: "160ms", "@media (prefers-reduced-motion: reduce)": "0ms" },
  durationSlow: { default: "240ms", "@media (prefers-reduced-motion: reduce)": "0ms" },
  easeStandard: "cubic-bezier(0.2, 0, 0, 1)",
  easeOut: "cubic-bezier(0, 0, 0.2, 1)",
  easeIn: "cubic-bezier(0.4, 0, 1, 1)",
  easeSpring: "cubic-bezier(0.34, 1.36, 0.64, 1)",
})
