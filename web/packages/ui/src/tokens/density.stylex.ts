import * as stylex from "@stylexjs/stylex"

/**
 * Sidebar density (apple/InlineMac/Features/Sidebar/SidebarChatItem.swift,
 * `SidebarItemSize`). Defaults are Compact, the Mac app's default for a new
 * install; the appearance controller applies Standard as a theme class.
 * `size.sidebarItem` (34, the Mac app's fixed top-item height) is unchanged.
 */
export const density = stylex.defineVars({
  /** Chat row height: 30 compact, 40 standard (one-line preview). */
  sidebarRowHeight: "30px",
  /** Folder row height: 30 compact, 32 standard. */
  sidebarFolderRowHeight: "30px",
  /** Chat icon size: 22 compact, 30 standard. */
  sidebarRowIconSize: "22px",
})
