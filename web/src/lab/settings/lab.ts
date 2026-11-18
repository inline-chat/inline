/**
 * The settings lab's state: a real `AppearanceController` on the document,
 * the fake platform with lab-controlled storage, notifications and updates,
 * an in-memory preferences store plus a second store standing in for another
 * tab, stubbed account data, and a small history so Back and Forward act like
 * the workspace's. Plain data for automation is `state()`; `control()` is the
 * operations the strip uses.
 */

import type { UserRow } from "@inline/core-protocol"
import { userId } from "@inline/ids"
import {
  available,
  isUserGesture,
  unavailable,
  type NotificationPermissionState,
  type Platform,
  type StorageEstimate,
  type UpdateState,
  type UserGesture,
} from "@inline/platform"
import { createFakePlatform, type FakePlatform } from "@inline/platform/testing"
import { computed, signal, type ReadSignal } from "@inline/reactive"
import {
  appearanceCommands,
  memoryAppearanceStorage,
  THEME_IDS,
  type Appearance,
  type AppearanceController,
  type ThemeId,
} from "@inline/ui/theme"
import {
  buildShortcutReference,
  CommandRegistry,
  isSettingsPage,
  registerNavigationCommands,
  Workspace,
  type OS,
  type SettingsPage,
  type ShortcutReference,
} from "@inline/view"
import { createPermissionPrompt, type PermissionPrompt } from "../../features/notifications/permission"
import {
  memoryPreferencesHub,
  memoryPreferencesStorage,
  PreferencesStore,
  type PreferenceValues,
  type SettingsAccount,
} from "../../features/settings"

export type LabPermission = NotificationPermissionState | "unavailable"
export type LabStorage = "persistent" | "notPersistent" | "unknown" | "unavailable"
export type LabEstimate = "measuring" | "small" | "large"
export type LabUpdate = "none" | "available" | "ready"
export type LabDir = "ltr" | "rtl"

const ESTIMATES: Record<Exclude<LabEstimate, "measuring">, StorageEstimate> = {
  small: { usage: 4_820_000, quota: 2_147_483_648 },
  large: { usage: 1_380_000_000, quota: 6_000_000_000 },
}

const ME: UserRow = {
  kind: "user",
  id: userId(1),
  firstName: "Ada",
  lastName: "Lovelace",
  username: "ada",
  email: "ada@example.com",
}

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

export class SettingsLab {
  readonly appearance: AppearanceController
  readonly hub = memoryPreferencesHub()
  /** The store the view edits. */
  readonly preferences: PreferencesStore
  /** Another tab on the same channel. */
  readonly otherTab: PreferencesStore

  readonly os = signal<OS>("mac")
  readonly permission = signal<LabPermission>("default")
  readonly storage = signal<LabStorage>("persistent")
  readonly estimate = signal<LabEstimate>("small")
  readonly update = signal<LabUpdate>("none")
  readonly narrow = signal(false)
  readonly dir = signal<LabDir>("ltr")
  readonly signedIn = signal(true)
  readonly accountLoading = signal(false)
  readonly pendingCount = signal(0)
  readonly mediaHandler = signal(true)
  readonly events = signal<readonly string[]>([])

  /** The pane's history, as the workspace keeps it. */
  readonly history = signal<{ readonly entries: readonly (SettingsPage | undefined)[]; readonly index: number }>({
    entries: [undefined],
    index: 0,
  })
  readonly page: ReadSignal<SettingsPage | undefined> = computed(() => {
    const { entries, index } = this.history.get()
    return entries[index]
  })

  readonly fake: ReadSignal<FakePlatform>
  readonly platform: ReadSignal<Platform>
  readonly prompt: ReadSignal<PermissionPrompt>
  readonly shortcuts: ReadSignal<ShortcutReference>
  readonly account: ReadSignal<SettingsAccount | undefined>

  readonly #me = signal<UserRow | undefined>(ME)
  readonly #persisted = signal<boolean | null>(true)
  readonly #estimate = signal<StorageEstimate | null>(ESTIMATES.small)
  readonly #fakes = new Map<OS, FakePlatform>()
  #signOuts = 0
  #clears = 0
  #refreshes = 0

  constructor(appearance: AppearanceController) {
    this.appearance = appearance
    this.preferences = new PreferencesStore({ storage: memoryPreferencesStorage(), channel: this.hub.channel(), instanceId: "lab" })
    this.otherTab = new PreferencesStore({ storage: memoryPreferencesStorage(), channel: this.hub.channel(), instanceId: "other" })

    this.fake = computed(() => this.#fakeFor(this.os.get()))
    // Recreated only when a capability appears or goes, as a real platform's would differ.
    const notificationsGone = computed(() => this.permission.get() === "unavailable")
    const storageGone = computed(() => this.storage.get() === "unavailable")
    this.platform = computed(() => {
      const fake = this.fake.get()
      const notifications = fake.platform.notifications
      return {
        ...fake.platform,
        notifications:
          notificationsGone.get() || !notifications.available
            ? unavailable("lab")
            : {
                ...notifications,
                requestPermission: async (gesture: UserGesture) => {
                  this.#log(`notifications: request permission (trusted gesture: ${isUserGesture(gesture)})`)
                  const result = await notifications.requestPermission(gesture)
                  this.permission.set(result)
                  return result
                },
              },
        links: {
          ...fake.platform.links,
          openExternal: (url: string) => {
            const opened = fake.platform.links.openExternal(url)
            this.#log(`link: ${opened ? "opened" : "refused"} ${url}`)
            return opened
          },
        },
        storage:
          storageGone.get()
            ? unavailable("lab")
            : available({
                persisted: this.#persisted,
                estimate: this.#estimate,
                canRequestSilently: true,
                requestPersistence: async () => this.#persisted.peek() === true,
                refreshEstimate: async () => {
                  this.#refreshes++
                  this.#log("storage: refresh estimate")
                },
              }),
      }
    })
    // One prompt per platform, as the notifications feature makes one per session.
    this.prompt = computed(() =>
      createPermissionPrompt({ notifications: this.platform.get().notifications }),
    )
    this.shortcuts = computed(() => buildShortcutReference(this.#registry(), { os: this.os.get(), surface: "browser" }))
    this.account = computed(() =>
      this.signedIn.get()
        ? {
            me: this.#me,
            deviceName: this.os.get() === "mac" ? "Chrome on macOS" : this.os.get() === "windows" ? "Edge on Windows" : "Firefox on Linux",
            signOut: async () => {
              this.#signOuts++
              this.#log("account: sign out")
              await delay(400)
            },
          }
        : undefined,
    )
  }

  /** The view's `onNavigate`: a new entry after the current one, as `workspace.open` does. */
  readonly navigate = (page: SettingsPage | undefined): void => {
    const { entries, index } = this.history.peek()
    if (entries[index] === page) return
    this.history.set({ entries: [...entries.slice(0, index + 1), page], index: index + 1 })
    this.#log(`navigate: ${page ?? "(settings)"}`)
  }

  readonly onClearCachedMedia = async (): Promise<void> => {
    this.#clears++
    this.#log("data: clear cached media")
    await delay(600)
    this.#estimate.set(this.#estimate.peek() ? { ...this.#estimate.peek()!, usage: 1_200_000 } : null)
  }

  back(): void {
    const { entries, index } = this.history.peek()
    if (index > 0) this.history.set({ entries, index: index - 1 })
  }

  forward(): void {
    const { entries, index } = this.history.peek()
    if (index < entries.length - 1) this.history.set({ entries, index: index + 1 })
  }

  /** The narrow one-column layout on the Appearance page: stacked rows (theme grid, line spacing) at about 400px. */
  showNarrowAppearance(): void {
    this.narrow.set(true)
    this.navigate("appearance")
  }

  setPermission(state: LabPermission): void {
    this.permission.set(state)
    if (state !== "unavailable") for (const fake of this.#fakes.values()) fake.notifications.setPermission(state)
  }

  setStorage(mode: LabStorage): void {
    this.storage.set(mode)
    this.#persisted.set(mode === "persistent" ? true : mode === "notPersistent" ? false : null)
  }

  setEstimate(kind: LabEstimate): void {
    this.estimate.set(kind)
    this.#estimate.set(kind === "measuring" ? null : ESTIMATES[kind])
  }

  setUpdate(status: LabUpdate, version = "2026.11.18"): void {
    this.update.set(status)
    const state: UpdateState = status === "none" ? { status } : { status, version }
    for (const fake of this.#fakes.values()) fake.updates.report(state)
  }

  setAccountLoading(loading: boolean): void {
    this.accountLoading.set(loading)
    this.#me.set(loading ? undefined : ME)
  }

  setDir(dir: LabDir): void {
    this.dir.set(dir)
    applyDir(dir)
  }

  setAppearance(appearance: Appearance): void {
    this.appearance.setAppearance(appearance)
  }

  setTheme(theme: ThemeId): void {
    this.appearance.setTheme(theme)
  }

  /** Another tab changes preferences; this tab must follow at once. */
  otherTabUpdate(patch: Partial<PreferenceValues>): void {
    this.otherTab.update(patch)
  }

  /** `state()` as a signal, for the lab's panel. */
  readonly snapshot: ReadSignal<ReturnType<SettingsLab["state"]>> = computed(() => {
    // Track everything the panel shows; `state()` itself only peeks.
    this.history.get()
    this.os.get()
    this.permission.get()
    this.storage.get()
    this.#estimate.get()
    this.update.get()
    this.narrow.get()
    this.dir.get()
    this.appearance.settings.get()
    this.preferences.value.get()
    this.otherTab.value.get()
    this.signedIn.get()
    this.accountLoading.get()
    this.pendingCount.get()
    this.mediaHandler.get()
    this.events.get()
    this.fake.get().platform.updater.state.get()
    this.prompt.get().showPrompt.get()
    return this.state()
  })

  state() {
    const fake = this.fake.peek()
    return {
      page: this.page.peek() ?? null,
      history: { entries: this.history.peek().entries.map((page) => page ?? null), index: this.history.peek().index },
      os: this.os.peek(),
      permission: this.permission.peek(),
      showPrompt: this.prompt.peek().showPrompt.peek(),
      permissionRequests: fake.notifications.permissionRequests,
      storage: this.storage.peek(),
      estimate: this.#estimate.peek(),
      estimateRefreshes: this.#refreshes,
      update: fake.platform.updater.state.peek(),
      openedLinks: [...fake.links.opened],
      narrow: this.narrow.peek(),
      dir: this.dir.peek(),
      appearance: this.appearance.settings.peek(),
      preferences: this.preferences.value.peek(),
      otherTabPreferences: this.otherTab.value.peek(),
      signedIn: this.signedIn.peek(),
      accountLoading: this.accountLoading.peek(),
      pendingCount: this.pendingCount.peek(),
      mediaHandler: this.mediaHandler.peek(),
      signOuts: this.#signOuts,
      clears: this.#clears,
      events: [...this.events.peek()],
    }
  }

  control() {
    return {
      navigate: (page: SettingsPage | undefined) => this.navigate(page),
      back: () => this.back(),
      forward: () => this.forward(),
      setOS: (os: OS) => this.os.set(os),
      setPermission: (state: LabPermission) => this.setPermission(state),
      setStorage: (mode: LabStorage) => this.setStorage(mode),
      setEstimate: (kind: LabEstimate) => this.setEstimate(kind),
      setUpdate: (status: LabUpdate, version?: string) => this.setUpdate(status, version),
      setNarrow: (narrow: boolean) => this.narrow.set(narrow),
      showNarrowAppearance: () => this.showNarrowAppearance(),
      setDir: (dir: LabDir) => this.setDir(dir),
      setAppearance: (appearance: Appearance) => this.setAppearance(appearance),
      setTheme: (theme: ThemeId) => this.setTheme(theme),
      setSignedIn: (signedIn: boolean) => this.signedIn.set(signedIn),
      setAccountLoading: (loading: boolean) => this.setAccountLoading(loading),
      setPendingCount: (count: number) => this.pendingCount.set(Math.max(0, Math.floor(count))),
      setMediaHandler: (on: boolean) => this.mediaHandler.set(on),
      otherTabUpdate: (patch: Partial<PreferenceValues>) => this.otherTabUpdate(patch),
      themes: THEME_IDS,
    }
  }

  expose(): void {
    Object.defineProperty(globalThis, "__settingsLab", { configurable: true, get: () => this.state() })
    ;(globalThis as { __settingsLabControl?: unknown }).__settingsLabControl = this.control()
  }

  #fakeFor(os: OS): FakePlatform {
    let fake = this.#fakes.get(os)
    if (!fake) {
      const permission = this.permission.peek()
      fake = createFakePlatform({
        os,
        notificationPermission: permission === "unavailable" ? "default" : permission,
        permissionAnswer: "granted",
      })
      const update = this.update.peek()
      if (update !== "none") fake.updates.report({ status: update, version: "2026.11.18" })
      fake.updates.setApplyHandler(() => this.#log("updater: apply (reload)"))
      this.#fakes.set(os, fake)
    }
    return fake
  }

  #registry(): CommandRegistry {
    const registry = new CommandRegistry()
    const noop = () => {}
    registerNavigationCommands(registry, {
      workspace: new Workspace(),
      selectAdjacentChat: noop,
      focusRegion: noop,
      openQuickSearch: noop,
      toggleSidebar: noop,
      openSettings: noop,
    })
    for (const spec of appearanceCommands(this.appearance)) registry.register(spec)
    return registry
  }

  #log(event: string): void {
    this.events.set([...this.events.peek().slice(-19), event])
  }
}

/** Starting state from the query string. */
export const labParams = (search: string) => {
  const params = new URLSearchParams(search)
  const pick = <T extends string>(key: string, options: readonly T[], fallback: T): T => {
    const value = params.get(key)
    return options.includes(value as T) ? (value as T) : fallback
  }
  return {
    page: ((page) => (page !== null && isSettingsPage(page) ? page : undefined))(params.get("page")),
    theme: pick<Appearance>("theme", ["light", "dark", "system"], "system"),
    dir: pick<LabDir>("dir", ["ltr", "rtl"], "ltr"),
    width: pick("width", ["wide", "narrow"], "wide"),
    os: pick<OS>("os", ["mac", "windows", "linux"], "mac"),
    permission: pick<LabPermission>("permission", ["default", "granted", "denied", "unavailable"], "default"),
    storage: pick<LabStorage>("storage", ["persistent", "notPersistent", "unknown", "unavailable"], "persistent"),
    update: pick<LabUpdate>("update", ["none", "available", "ready"], "none"),
  }
}

export const applyDir = (dir: LabDir): void => {
  document.documentElement.dir = dir
}

export const labAppearanceStorage = () => memoryAppearanceStorage()
