/**
 * @inline/ui: our UI kit's framework-free half. Headless controllers and the
 * foundations they share. Views live in `@inline/ui/react`; tokens in
 * `src/tokens/*.stylex.ts`. See README.md.
 */

// Foundations
export { type Clock, createManualClock, type ManualClock, systemClock, Timer, type TimerHandle } from "./foundations/clock"
export { isUsable, type NavAction, type NavItem, type NavOptions, navigate } from "./foundations/collection"
export {
  type DismissLayer,
  type DismissLayerOptions,
  type DismissReason,
  openLayerCount,
  pushDismissLayer,
} from "./foundations/dismiss"
export {
  type Direction,
  type Dispose,
  directionOf,
  isPrintableKey,
  type KeyInput,
  type Rect,
} from "./foundations/dom"
export {
  activateFocusScope,
  type FocusScope,
  type FocusScopeOptions,
  type FocusTarget,
  getTabbables,
  isFocusable,
  RovingTabIndex,
} from "./foundations/focus"
export { HoverIntent, type HoverIntentOptions, isPointInPolygon, type Point, safePolygon } from "./foundations/hover-intent"
export { childId, createId } from "./foundations/id"
export { Lazy } from "./foundations/lazy"
export { ariaKeyShortcuts, ariaKeyShortcutsFromHint, type ShortcutCombo } from "./foundations/shortcuts"
export {
  type AnchorSource,
  hideLayer,
  LAYER_ATTRIBUTE,
  type PlaceOptions,
  placeLayer,
  raiseLayer,
  showLayer,
  trackLayer,
} from "./foundations/layer"
export { combineParts, type Part } from "./foundations/parts"
export { createModalityTracker, type Modality, type ModalityTracker, acquireModality } from "./foundations/modality"
export { detectPlatform, hasCommandModifier, type PlatformKind } from "./foundations/platform"
export {
  type Align,
  computePosition,
  type LogicalSide,
  type PhysicalSide,
  type Placement,
  type PositionInput,
  type PositionResult,
  type Side,
} from "./foundations/position"
export { findTypeaheadMatch, normalizeText, Typeahead, type TypeaheadItem } from "./foundations/typeahead"

// Controllers
export { type AvatarStyle, avatarPalette, avatarPaletteIndex, avatarSeed, avatarStyle, initials } from "./avatar/avatar"
export {
  type ComboboxOptions,
  ComboboxController,
  type ComboboxStatus,
  defaultComboboxFilter,
} from "./combobox/controller"
export { ContextMenuController, type ContextMenuOptions } from "./context-menu/controller"
export { loadMenuKit, type MenuKit, type MenuKitCore, menuKit } from "./context-menu/kit"
export { LazyContextMenu, type LazyContextMenuOptions, type MenuKitSource } from "./context-menu/lazy"
export {
  type ContextMenuInvocation,
  type ContextMenuRequestEvent,
  ContextMenuTrigger,
  type ContextMenuTriggerOptions,
  isContextMenuKey,
} from "./context-menu/trigger"
export {
  createSheet,
  type DialogCloseReason,
  DialogController,
  type DialogOptions,
} from "./dialog/controller"
export { ListboxController, type ListboxOption, type ListboxOptions } from "./listbox/controller"
export { type SelectionMode, SelectionModel, type SelectionOptions } from "./listbox/selection"
export {
  type CloseOptions,
  createMenu,
  type FocusableEntry,
  isFocusableEntry,
  MenuController,
  type MenuEntry,
  type MenuOpenOptions,
  type MenuOptions,
} from "./menu/controller"
export { PopoverController, type PopoverOptions } from "./popover/controller"
export { type PaneSpec, SplitViewController, type SplitViewOptions, type SplitViewState } from "./split-view/controller"
export { TabsController, type TabSpec, type TabsOptions } from "./tabs/controller"
export {
  DEFAULT_TOAST_OFFSET,
  type Toast,
  type ToastInput,
  type ToastOffset,
  type ToastPlacement,
  toastPlacement,
  ToastQueue,
  type ToastQueueOptions,
  type ToastTone,
} from "./toast/controller"
export { ToggleController, type ToggleOptions } from "./toggle/controller"
export {
  defaultTooltipGroup,
  TooltipController,
  TooltipGroup,
  type TooltipGroupOptions,
  type TooltipOptions,
} from "./tooltip/controller"

// Appearance and themes (framework-free; the StyleX binding is `@inline/ui/theme/stylex`)
export * from "./theme"
