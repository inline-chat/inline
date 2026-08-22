import * as stylex from "@stylexjs/stylex"

const dark = "@media (prefers-color-scheme: dark)"

export const landingColors = stylex.defineVars({
  canvas: { default: "#fbfbfa", [dark]: "#111111" },
  text: { default: "#171717", [dark]: "#f4f4f4" },
  secondaryText: { default: "#686864", [dark]: "#aaa9a3" },
  border: { default: "#e2e2de", [dark]: "#353533" },
  control: { default: "#f0f0ed", [dark]: "#222220" },
  controlHover: { default: "#e8e8e4", [dark]: "#2b2b28" },
  elevated: { default: "#ffffff", [dark]: "#242422" },
  selectedControl: { default: "#ffffff", [dark]: "#3a3a37" },
  selectedText: { default: "#171717", [dark]: "#ffffff" },
  itemHighlight: { default: "#f1f1ee", [dark]: "#343431" },
  focus: { default: "#3f6fd8", [dark]: "#8aabf3" },
  popupShadow: {
    default: "0 12px 38px rgba(22, 22, 20, 0.14), 0 2px 8px rgba(22, 22, 20, 0.08)",
    [dark]: "0 16px 44px rgba(0, 0, 0, 0.48), 0 2px 10px rgba(0, 0, 0, 0.32)",
  },
})

export const lightTheme = stylex.createTheme(landingColors, {
  canvas: "#fbfbfa",
  text: "#171717",
  secondaryText: "#686864",
  border: "#e2e2de",
  control: "#f0f0ed",
  controlHover: "#e8e8e4",
  elevated: "#ffffff",
  selectedControl: "#ffffff",
  selectedText: "#171717",
  itemHighlight: "#f1f1ee",
  focus: "#3f6fd8",
  popupShadow: "0 12px 38px rgba(22, 22, 20, 0.14), 0 2px 8px rgba(22, 22, 20, 0.08)",
})

export const darkTheme = stylex.createTheme(landingColors, {
  canvas: "#111111",
  text: "#f4f4f4",
  secondaryText: "#aaa9a3",
  border: "#353533",
  control: "#222220",
  controlHover: "#2b2b28",
  elevated: "#242422",
  selectedControl: "#3a3a37",
  selectedText: "#ffffff",
  itemHighlight: "#343431",
  focus: "#8aabf3",
  popupShadow: "0 16px 44px rgba(0, 0, 0, 0.48), 0 2px 10px rgba(0, 0, 0, 0.32)",
})
