import * as stylex from "@stylexjs/stylex"
import { colors } from "./tokens.stylex"

// A constant can be used to avoid repeating the media query
const DARK = "@media (prefers-color-scheme: dark)"

// Dracula theme
export const darkTheme = stylex.createTheme(colors, {})
