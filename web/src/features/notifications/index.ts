/**
 * Message notifications, the unread badge and the notification permission
 * affordance for a signed-in session. Framework-free; see README.md.
 */
export { attachNotifications, type AttachNotificationsOptions, type NotificationsAttachment } from "./attach"
export { attachBadge, type BadgeControllerOptions, type BadgeTarget } from "./badge"
export {
  createNotificationController,
  type CoreRole,
  type MessageNotificationData,
  type NotificationController,
  type NotificationControllerOptions,
  type NotificationSession,
  type NotificationSettings,
  type NotificationSoundEvent,
} from "./notification-controller"
export {
  createPermissionPrompt,
  PROMPT_DISMISSED_KEY,
  type PermissionPrompt,
  type PermissionPromptOptions,
  type PermissionState,
  type PromptStorage,
} from "./permission"
export { createViewingTracker, chatsInPanes, type ViewingChannel, type ViewingTracker } from "./viewing"
export { notificationBody, notificationContent, type NotificationContent } from "./content"
