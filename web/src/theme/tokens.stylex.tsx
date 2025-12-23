import * as stylex from "@stylexjs/stylex"

// A constant can be used to avoid repeating the media query
const DARK = "@media (prefers-color-scheme: dark)"

export const colors = stylex.defineVars({
  // General Colors
  accent: { default: "blue", [DARK]: "lightblue" },
  lineColor: { default: "gray", [DARK]: "lightgray" },

  // Background Colors
  primaryBg: { default: "white", [DARK]: "black" },
  secondaryBg: { default: "gray", [DARK]: "darkgray" },
  tertiaryBg: { default: "darkgray", [DARK]: "darkergray" },
  quaternaryBg: { default: "darkergray", [DARK]: "darkestgray" },
  quinaryBg: { default: "darkestgray", [DARK]: "black" },

  // Text Colors
  primaryText: { default: "black", [DARK]: "white" },
  secondaryText: { default: "#333", [DARK]: "#ccc" },
  whiteText: { default: "white", [DARK]: "white" },
})
