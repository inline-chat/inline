import * as stylex from "@stylexjs/stylex"

export const colors = stylex.defineVars({
  window: "light-dark(#f6f6f6, #1e1e1f)",
  content: "light-dark(#ffffff, #242426)",
  replyPane: "light-dark(#fbfbfb, #29292b)",
  sidebar: "light-dark(rgba(244, 244, 244, 0.96), rgba(35, 35, 37, 0.96))",
  textPrimary: "light-dark(#151515, #f3f3f3)",
  textSecondary: "light-dark(rgba(0, 0, 0, 0.56), rgba(255, 255, 255, 0.58))",
  textTertiary: "light-dark(rgba(0, 0, 0, 0.38), rgba(255, 255, 255, 0.38))",
  separator: "light-dark(rgba(0, 0, 0, 0.09), rgba(255, 255, 255, 0.09))",
  selected: "light-dark(rgba(0, 0, 0, 0.07), rgba(255, 255, 255, 0.10))",
  hovered: "light-dark(rgba(0, 0, 0, 0.05), rgba(255, 255, 255, 0.06))",
  control: "light-dark(rgba(255, 255, 255, 0.86), rgba(255, 255, 255, 0.08))",
  controlHover: "light-dark(rgba(255, 255, 255, 1), rgba(255, 255, 255, 0.12))",
  controlOutline: "light-dark(rgba(0, 0, 0, 0.09), rgba(255, 255, 255, 0.10))",
  skeleton: "light-dark(rgba(0, 0, 0, 0.075), rgba(255, 255, 255, 0.085))",
  outgoingBubble: "light-dark(rgb(143, 116, 238), rgb(120, 94, 212))",
  incomingBubble: "light-dark(rgb(236, 236, 236), rgba(255, 255, 255, 0.10))",
  outgoingText: "#ffffff",
  accent: "light-dark(rgb(123, 91, 228), rgb(155, 130, 239))",
  destructive: "light-dark(#d70015, #ff6961)",
  unread: "light-dark(#6f49e8, #9b82ef)",
  shadow: "light-dark(rgba(0, 0, 0, 0.14), rgba(0, 0, 0, 0.42))",
})

export const metrics = stylex.defineVars({
  toolbarHeight: "46px",
  sidebarMinWidth: "180px",
  sidebarIdealWidth: "240px",
  sidebarMaxWidth: "340px",
  sidebarRadius: "10px",
  sidebarContentInset: "17px",
  sidebarInnerInset: "11px",
  sidebarOuterInset: "6px",
  sidebarRowHeight: "44px",
  sidebarIconSize: "32px",
  messageMaxWidth: "420px",
  messageSideInset: "16px",
  messageAvatarSize: "28px",
  messageBubbleRadius: "14px",
  composeMinHeight: "44px",
  composeOuterInset: "18px",
  composeButtonSize: "28px",
})

export const typography = stylex.defineVars({
  body: "13px",
  sidebarTitle: "13px",
  sidebarPreview: "11px",
  callout: "12px",
  footnote: "10px",
  onboardingTitle: "21px",
})
