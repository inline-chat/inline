import * as stylex from "@stylexjs/stylex"
import { colors } from "./tokens.stylex"

// A constant can be used to avoid repeating the media query
const DARK = "@media (prefers-color-scheme: dark)"

// Dracula theme
export const darkTheme = stylex.createTheme(colors, {
  accent: { default: "#222", [DARK]: "white" },
  lineColor: { default: "gray", [DARK]: "white" },

  primaryBg: { default: "black", [DARK]: "white" },
  secondaryBg: { default: "gray", [DARK]: "white" },
  tertiaryBg: { default: "darkgray", [DARK]: "white" },
  quaternaryBg: { default: "darkergray", [DARK]: "white" },
  quinaryBg: { default: "darkestgray", [DARK]: "white" },

  primaryText: { default: "white", [DARK]: "black" },
  secondaryText: { default: "gray", [DARK]: "white" },
})
