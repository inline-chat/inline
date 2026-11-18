/** The sidebar feature: mount `SidebarView` with the session's `SidebarModel`. See README.md. */

export { SidebarView, type SidebarViewProps } from "./SidebarView"
export { SidebarRow, SidebarAvatar, type UnreadStyle } from "./SidebarRow"
export { SidebarHandle, type SidebarSnapshot } from "./handle"
export {
  SidebarController,
  type SidebarCallbacks,
  type SidebarControllerOptions,
  type SidebarOpenEvent,
  type SidebarSource,
  type SidebarStatus,
  type SlotView,
} from "./sidebar-controller"
export {
  basicActions,
  canFollow,
  dialogSettingActions,
  type FollowChoice,
  NOTIFICATION_CHOICES,
  type NotificationChoice,
  notificationChoiceOf,
  toMenuEntries,
  type BasicActionHandlers,
  type SidebarAction,
  type SidebarActions,
} from "./actions"
export { sameActivityStatus, type SidebarActivity, type SidebarActivityStatus, type SidebarTypingSource } from "./activity"
export { openIntentFor, pointerOpenIntent, type Modifiers, type OpenIntentMap } from "./keyboard"
export { rowMetrics, type RowMetrics, type SidebarDensity } from "./geometry"
export { assignSlots, enteringKeys, type SlotKeys } from "./slots"
