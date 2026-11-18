/**
 * @inline/platform: one capability interface with a web implementation now
 * and an Electron one later. Importing this module touches no browser global;
 * only calling `createWebPlatform` (without an `env`) does.
 */

export type {
  Badge,
  BadgeSetOptions,
  Files,
  FreezeEvent,
  FreezeSource,
  GlobalShortcut,
  LaunchAtLogin,
  Lifecycle,
  Links,
  NotificationAction,
  NotificationActionEvent,
  NotificationClick,
  NotificationData,
  NotificationPermissionState,
  NotificationRequest,
  Notifications,
  OperatingSystem,
  PageHideEvent,
  PersistentStorage,
  Platform,
  PlatformInfo,
  PlatformKind,
  SaveOutcome,
  Spellcheck,
  StorageEstimate,
  TitleBarInsets,
  Tray,
  TrayChat,
  Updater,
  UpdateState,
  WakeEvent,
  WindowChrome,
} from "./platform"
export { available, DESKTOP_ONLY, unavailable, type Available, type Capability, type Unavailable } from "./capability"
export { systemClock, type Clock, type TimerHandle } from "./clock"
export { isUserGesture, userGesture, type GestureEventLike, type UserGesture } from "./gesture"
export {
  chatNotificationGroup,
  decideMessageNotification,
  isFreshMessage,
  isViewingConversation,
  MAX_NOTIFICATION_AGE_MS,
  messageNotificationTag,
  resolveNotificationMode,
  type ChatNotificationMode,
  type EffectiveNotificationMode,
  type GlobalNotificationMode,
  type MessageNotificationFacts,
  type NotificationDecision,
  type NotificationSkipReason,
} from "./notification-policy"
export {
  BADGE_INCREASE_DEBOUNCE_MS,
  badgeLabel,
  createBadgeController,
  normalizeCount,
  type BadgeController,
} from "./badge-policy"
export { createWakeDetector, WAKE_INTERVAL_MS, WAKE_TOLERANCE_MS, type WakeDetector } from "./wake-detector"
export { createUpdateFeed, type UpdateFeed } from "./update-feed"
export type { DesktopBridge } from "./desktop-bridge"
export { createWebPlatform, type WebPlatform, type WebPlatformOptions } from "./web"
export { webEnvFromGlobals, type WebEnv } from "./web/env"
export type { FaviconRenderer } from "./web/favicon"
export { canvasFaviconRenderer } from "./web/favicon"
export type { ExternalUrlCheck } from "./web/links"
