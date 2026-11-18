/**
 * Settings: the `settings` destination's view and the local preferences
 * store other features read. See README.md.
 */

export { SettingsView } from "./SettingsView"
export type { SettingsAccount, SettingsViewProps } from "./types"
export {
  broadcastPreferencesChannel,
  cleanPatch,
  DEFAULT_PREFERENCES,
  memoryPreferencesHub,
  memoryPreferencesStorage,
  parsePreferences,
  PREFERENCE_KEYS,
  PREFERENCES_MESSAGE_TYPE,
  PREFERENCES_STORAGE_KEY,
  PREFERENCES_VERSION,
  PreferencesStore,
  SEND_KEYS,
  webPreferencesStorage,
  type PreferenceKey,
  type Preferences,
  type PreferencesChannel,
  type PreferencesMessage,
  type PreferencesStorage,
  type PreferencesStoreOptions,
  type PreferencesSyncSource,
  type PreferenceValues,
  type SendKey,
} from "./preferences"
export {
  DEFAULT_SETTINGS_PAGE,
  isSettingsPageId,
  SETTINGS_ITEMS,
  SETTINGS_PAGES,
  type SettingsItemId,
  type SettingsPageId,
} from "./catalog"
export { buildSearchIndex, searchSettings, type SettingsSearchEntry } from "./search"
export { SettingsModel, type SettingsModelOptions } from "./settings-model"
