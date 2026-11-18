/**
 * The appearance commands, shaped like `@inline/view`'s `CommandSpec` so the
 * registry can register them as they are (this package does not depend on
 * `view`). Titles and keys are the Mac app's View menu (AppMenu.swift,
 * `setupTextSizeMenuItems`).
 *
 * Cmd+0, Cmd+= and Cmd+- are the browser's zoom keys, so in a browser tab
 * they are unbound (`browser: { default: [] }`) and the commands stay in the
 * command bar and the View menu; the desktop app binds them.
 */

import { computed, type ReadSignal } from "@inline/reactive"
import type { AppearanceController } from "./controller"
import type { Appearance } from "./settings"

export type AppearanceCommandSpec = {
  readonly id: string
  readonly title: string
  readonly category: "view"
  readonly shortcuts?: { readonly default?: readonly string[]; readonly browser?: { readonly default?: readonly string[] } }
  readonly enabled?: ReadSignal<boolean>
  readonly repeat?: boolean
  readonly run: () => void
}

export const APPEARANCE_COMMAND_IDS = {
  textSizeReset: "view.textSize.reset",
  textSizeIncrease: "view.textSize.increase",
  textSizeDecrease: "view.textSize.decrease",
  appearanceLight: "view.appearance.light",
  appearanceDark: "view.appearance.dark",
  appearanceSystem: "view.appearance.system",
} as const

const unboundInBrowser = (keys: readonly string[]) => ({ default: keys, browser: { default: [] as string[] } })

export function appearanceCommands(controller: AppearanceController): AppearanceCommandSpec[] {
  const appearance = (id: string, title: string, value: Appearance): AppearanceCommandSpec => ({
    id,
    title,
    category: "view",
    enabled: computed(() => controller.appearance.get() !== value),
    run: () => controller.setAppearance(value),
  })
  return [
    {
      id: APPEARANCE_COMMAND_IDS.textSizeReset,
      title: "Make Text Normal Size",
      category: "view",
      shortcuts: unboundInBrowser(["Mod+0"]),
      enabled: computed(() => !controller.isDefaultTextSize.get()),
      run: () => controller.resetTextSize(),
    },
    {
      id: APPEARANCE_COMMAND_IDS.textSizeIncrease,
      title: "Make Text Bigger",
      category: "view",
      // Cmd+= is the unshifted Cmd++ on most layouts; the Mac app binds both.
      shortcuts: unboundInBrowser(["Mod+=", "Mod+Shift+="]),
      enabled: controller.canIncreaseTextSize,
      repeat: true,
      run: () => {
        controller.increaseTextSize()
      },
    },
    {
      id: APPEARANCE_COMMAND_IDS.textSizeDecrease,
      title: "Make Text Smaller",
      category: "view",
      shortcuts: unboundInBrowser(["Mod+-"]),
      enabled: controller.canDecreaseTextSize,
      repeat: true,
      run: () => {
        controller.decreaseTextSize()
      },
    },
    appearance(APPEARANCE_COMMAND_IDS.appearanceLight, "Use Light Appearance", "light"),
    appearance(APPEARANCE_COMMAND_IDS.appearanceDark, "Use Dark Appearance", "dark"),
    appearance(APPEARANCE_COMMAND_IDS.appearanceSystem, "Use System Appearance", "system"),
  ]
}
