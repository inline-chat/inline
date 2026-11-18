/**
 * @inline/ui/theme: appearance and themes, framework-free and runnable in
 * Node (no StyleX at runtime). The StyleX binding is `@inline/ui/theme/stylex`.
 * See README.md in this directory.
 */

export {
  isThemeId,
  THEME_IDS,
  THEME_SEEDS,
  THEME_TITLES,
  type ThemeId,
  type Variant,
  VARIANTS,
} from "./catalog"
export {
  blend,
  composite,
  contrastRatio,
  parseColor,
  relativeLuminance,
  type Rgba,
  splitLightDark,
  toHex,
  WCAG_AA_BODY_TEXT,
  WCAG_AA_LARGE_TEXT,
  WCAG_AA_NON_TEXT,
} from "./color-math"
export { APPEARANCE_COMMAND_IDS, type AppearanceCommandSpec, appearanceCommands } from "./commands"
export { CONTRAST_PAIRS, type ContrastPair, type ContrastRow, contrastRows } from "./contrast"
export {
  type AppearanceBinding,
  AppearanceController,
  type AppearanceControllerOptions,
  type AppearancePatch,
  type AppearanceRootElement,
  EMOJI_SIZES,
  type MatchMedia,
  type MediaQueryListLike,
  NATURAL_LINE_HEIGHT,
  ROOT_ATTRIBUTES,
  typographyVariables,
} from "./controller"
export {
  canvasColors,
  FORCED_COLORS,
  resolveTheme,
  type ResolvedTheme,
  SHARED_COLOR_TOKENS,
  THEME_COLOR_TOKENS,
  THEMED_COLOR_TOKENS,
} from "./palette"
export {
  APPEARANCE_SETTINGS_VERSION,
  type Appearance,
  APPEARANCES,
  type AppearanceSettings,
  DEFAULT_APPEARANCE_SETTINGS,
  DEFAULT_TEXT_SIZE,
  LINE_SPACING_STEPS,
  lineSpacingTitle,
  MAX_TEXT_SIZE,
  MESSAGE_FONTS,
  MESSAGE_STYLES,
  type MessageFont,
  type MessageStyle,
  MIN_TEXT_SIZE,
  nextLargerTextSize,
  nextSmallerTextSize,
  parseAppearanceSettings,
  serializeAppearanceSettings,
  SIDEBAR_ITEM_SIZES,
  type SidebarItemSize,
  TEXT_SIZE_STEPS,
  UNREAD_BADGE_STYLES,
  type UnreadBadgeStyle,
} from "./settings"
export {
  APPEARANCE_BOOT_KEY,
  APPEARANCE_STORAGE_KEY,
  type AppearanceStorage,
  type BootRecord,
  localAppearanceStorage,
  memoryAppearanceStorage,
} from "./storage"
