# Theming

Appearance (light, dark, follow the system), the Mac app's eight themes, and the message text and sidebar density settings. The model is a framework-free controller over one settings object; StyleX supplies the classes and variables it writes onto a root element.

## Model

- **Settings** (`settings.ts`): one plain object, `AppearanceSettings`, with a `version` (1). `parseAppearanceSettings(anything)` never throws and keeps every valid field; invalid fields take their defaults. Unversioned objects are read with legacy spellings (the Mac's "Auto", the old iOS theme names, sizes as strings); newer versions are read field by field. Defaults are the Mac app's for a new install: appearance system, theme System, text 13, line spacing 1 (Standard), system font, Compact sidebar, bubbles, dot badges, unified toolbar, centered chats.
- **Storage** (`storage.ts`): `AppearanceStorage { read, write }`, synchronous. `localAppearanceStorage()` never throws. Settings live under `inline.appearance`, device-wide (appearance is chosen before an account is known). The core can sync them later by implementing the same interface and calling `controller.reload()` on a remote change.
- **Controller** (`controller.ts`): `AppearanceController` exposes every field as a signal, plus `resolvedAppearance`, `systemPrefersDark`, `canIncreaseTextSize`, `canDecreaseTextSize` and `isDefaultTextSize`. Setters (`setAppearance`, `setTheme`, `setTextSize`, `increaseTextSize`, `decreaseTextSize`, `resetTextSize`, `setLineSpacing`, `setMessageFont`, `setSidebarItemSize`, `setMessageStyle`, `setUnreadBadgeStyle`, `setCompactToolbar`, `setCenteredChats`, `update(patch)`, `resetMessageText`, `reset`) write the signal, the root and the storage in the same task. `attach(element)` applies and keeps applying to an element and returns a detach that removes exactly what it added; it is a part, so `useElement(controller)` works. `matchMedia` is injected; with "system" the resolved appearance follows its `change` events.
- **What lands on the root:**
  - classes: the canvas (`background-color: windowBackground`, `color: label`), the `color-scheme` (`light`, `dark`, or `light dark` for system), the theme, Standard density, the monospace message font. Classes the controller did not add are left alone.
  - attributes: `data-appearance`, `data-resolved-appearance`, `data-theme`.
  - CSS variables, only when not at the default: message font size, line height, and the three emoji-only sizes.
- **Binding** (`stylex-binding.ts`, exported as `@inline/ui/theme/stylex`): the real class names and variable names. It needs the StyleX compiler, so tests use `fakeBinding` from `testing.ts`. `startDocumentAppearance()` creates the document controller (local storage, `window.matchMedia`), attaches it to `<html>`, and reloads on `storage` events from other tabs.
- **Commands** (`commands.ts`): `appearanceCommands(controller)` returns specs shaped like `@inline/view`'s `CommandSpec`: Make Text Normal Size, Bigger, Smaller (`Mod+0`, `Mod+=` and `Mod+Shift+=`, `Mod+-`, as in AppMenu.swift) and the three appearances. In a browser tab those keys are the browser's zoom, so they are unbound there (`browser: { default: [] }`) and the desktop app binds them.
- **Views** (`../react/Appearance.tsx`): `AppearanceScope` (a subtree bound to a controller), `ThemeScope` (a subtree with a fixed theme and appearance), `SegmentedControl` (native radios), `AppearanceSwitch`, `ThemeSwatchGrid` (each swatch drawn with its own theme's tokens), `TextSizeStepper`, `LineSpacingControl`, `MessageFontControl`, `SidebarItemSizeControl`. No effects.

## Tokens

Existing token names and normal-mode values are unchanged. Added:

- `tokens/chat-text.stylex.ts` (`chatText`): `messageFontFamily` (defaults to `font.familySystem`), `messageFontSize` (`font.sizeBody`), `messageLineHeight` (`font.lineHeightTight`), `emojiLarge` 64px, `emojiMedium` 42px, `emojiSmall` 18px. Message views read these instead of `font`.
- `tokens/density.stylex.ts` (`density`): `sidebarRowHeight` 30 / 40, `sidebarFolderRowHeight` 30 / 32, `sidebarRowIconSize` 22 / 30 (Compact / Standard). `size.sidebarItem` (34) is unchanged; it is the Mac app's fixed top-item height.
- `tokens/theme-color.stylex.ts` (`themeColor`, generated): `secondaryBubbleLink`, `replyPaneBackground`.

Changed in `tokens/color.stylex.ts`, conditions only:

- `forced-colors: active`: `link` to LinkText, `focusRing` to Highlight, `selectedContentBackground` and `selectedMenuItem` to Highlight, `selectedText` and `selectedMenuItemText` to HighlightText.
- `prefers-reduced-transparency: reduce`: `menuBackground`, `popoverBackground`, `tooltipBackground` become the same colors, opaque.

## Themes

`catalog.ts` holds the Mac catalog as data; `palette.ts` derives every value with the Mac app's formulas; `generate.ts` renders `themes.ts` (one `createTheme` per theme for `color` and one for `themeColor`) and `tokens/theme-color.stylex.ts`. StyleX needs literal values, so these files are checked in; `generate.test.ts` fails if they drift.

A theme sets these `color` tokens, all of them, the System theme included: `accent`, `accentHover`, `accentPressed`, `prominent`, `focusRing`, `bubble`, `windowBackground`, `sidebarBackground`, `secondaryBubble`; and both `themeColor` tokens. Every other `color` token is listed in `SHARED_COLOR_TOKENS`: AppKit values the Mac app does not theme either. A test reads `color.stylex.ts` and fails unless the two lists partition it exactly, so a new token must be classified.

### Where each value comes from

| Token | Source | Rule |
| --- | --- | --- |
| `accent`, `prominent`, `bubble` | `ThemeCatalog.palette` primary | as is |
| `windowBackground` | `Theme.resolvedWindowSurfaceColor` | native window color blended toward the canvas seed, 5.6% light, 8.4% dark; System uses the native color |
| `sidebarBackground` | `Theme.resolvedSidebarOverlayColor` | primary at 2.625% (light) / 4.2% (dark) over the sidebar color; none for System (glass and tint on, the Mac default) |
| `secondaryBubble` | `ThemeCatalog.secondaryBubble` | #ECECEC System light, #EAEAEA light, #2E2E2E dark |
| `secondaryBubbleLink` | `Theme.resolvedSecondaryBubbleLinkColor` | HSB: light caps brightness at 0.88; dark keeps hue, 48% saturation, brightness max(0.9, b + 0.15) |
| `replyPaneBackground` | `Theme.replyThreadPaneBackgroundColor` | window color blended 2.5% toward black (light) or white (dark); System uses the window color |
| `accentHover`, `accentPressed` | the kit's System values | not in the Mac app (AppKit draws pressed states). Light: 0.928 and 0.846 of the primary; dark: 9.5% and 19.5% toward white. This reproduces the kit's System values exactly (tested) |
| `focusRing` | the kit's System value | the primary at 55% (light) / 70% (dark) |

The "native" window and sidebar colors are the kit's `windowBackground` (#ffffff / #1e1e1e) and `sidebarBackground`, so System on the web is the kit unchanged (tested).

### Adding a theme

1. Add it to the Mac catalog first (`ThemeCatalog.swift`); the web follows the Mac app.
2. Add its ID, title and seeds to `catalog.ts`, its export pair to `themeClasses` in `stylex-binding.ts` and to `fakeBinding` in `testing.ts`.
3. Run `UPDATE_THEMES=1 bunx vitest run src/theme/generate.test.ts` to regenerate, then `bun run test`. The contrast test fails if a pair falls under AA; decide with the Mac app, and list any value kept anyway in `KNOWN_FAILURES` with its ratio.

### Contrast

`contrastRows()` measures each pair in `CONTRAST_PAIRS` for every theme in light and dark (WCAG 2, translucent text composited first). Body text on every surface (window, sidebar, reply pane, others' bubbles, selected rows) passes in every theme. These Mac values fail AA and are kept, pinned in `contrast.test.ts`:

- White on the outgoing bubble and on accent buttons: System light 2.66 (#00A7F8), System dark 3.64 (#0A84FF), Pink light and dark 3.18 (#FD4F7E). The Mac app also lightens the top of bubbles with a white overlay, which lowers these further.
- Links in others' bubbles: System light 2.73, Pink light 3.30, Sunset light 3.81, Midnight light 4.31, Pastel light 4.35.
- AppKit's secondary label (black at 50%) on light windows: 3.96 to 3.97 in every theme (it passes under Increase Contrast, at 70%).
- The accent as an icon or indicator (3:1): System light 2.66, and Ash (1.85), Flexoki (2.57) and Neon Noir (2.63) dark, whose primaries are dark on a dark window.

## Before first paint

The page must paint the chosen appearance from the first frame, under a policy that forbids inline scripts. Before the app's module runs, the page is only its canvas, so the canvas color and `color-scheme` are all that must be right; the module applies everything else before React renders.

1. `boot.js` is a classic script (no imports, under 2 KB) loaded with a plain `<script src>` in `<head>`. Classic scripts block parsing, so it runs before the first paint. It reads `inline.appearance.boot`, resolves "system" with `matchMedia`, and sets `color-scheme` and `background-color` on `<html>` through the CSSOM, which the policy allows, plus `data-appearance-boot`.
2. The controller writes that record (`{ v: 1, a, l, d }`: the appearance and the theme's opaque window color in light and dark) whenever the appearance or theme changes, so the script needs no theme table.
3. The app's entry module calls `startDocumentAppearance()` first, before `createRoot().render`. Attaching applies the classes and then, in the same task, removes the boot script's inline stand-ins.

The cost is one small blocking same-origin request in `<head>`; it is cacheable and the service worker can serve it.

Wiring it into the app (shared files, for the coordinator): `lab-theme.html` loads it in dev as `<script src="/packages/ui/src/theme/boot.js"></script>`. A production build will not copy a classic script, so `vite.config.ts` needs a small plugin, for example:

```ts
import { readFileSync } from "node:fs"
const bootPath = new URL("./packages/ui/src/theme/boot.js", import.meta.url)
function appearanceBoot(): Plugin {
  return {
    name: "inline-appearance-boot",
    buildStart() {
      this.emitFile({ type: "asset", fileName: "appearance-boot.js", source: readFileSync(bootPath, "utf8") })
    },
    transformIndexHtml(_html, context) {
      const src = context.server ? "/packages/ui/src/theme/boot.js" : "/appearance-boot.js"
      return [{ tag: "script", attrs: { src }, injectTo: "head" }]
    },
  }
}
```

and `src/main.tsx` starts with `const appearance = startDocumentAppearance()` (from `@inline/ui/theme/stylex`). The unhashed file name needs a short cache lifetime or revalidation.

## Platform accents

- **Forced colors:** themes set no `forced-color-adjust` and never fight the browser's forcing (tested). Only token pairs that always travel together are mapped to system colors (selection background and text, links, the focus ring), which the browser keeps because author system colors are honored; everything else is forced to Canvas and CanvasText by the browser. Selection and focus therefore stay visible. Views that show state only through a background (a checked switch track, an accent badge) still need a border or an indicator in forced colors.
- **Increase contrast:** the kit's `prefers-contrast: more` branches (secondary label, separators, borders) are on tokens themes do not set; a test fails if a theme ever drops a condition its base token has.
- **Reduced transparency:** menus, popovers and tooltips turn opaque, which also hides their backdrop blur.
- **Reduced motion:** unchanged; motion tokens drop to 0ms.

## Fonts

Only the system UI stack and the system monospace stack, never a downloaded font: the content policy allows only same-origin fonts (`font-src 'self'`), and a font file on the first-paint path costs a request and either a flash of fallback text or blocked text. The Mac app's named families, fallback fonts and code font are left for later.

## Check in a real browser

- No flash on reload for each appearance and theme, including "system" with the OS in dark, and first visit (no record).
- `light-dark()` tokens follow the root's `color-scheme` class and nested `ThemeScope` panels.
- Live OS appearance change while "system" is chosen.
- Forced colors (Windows High Contrast, or Chromium's emulation): selection, links and focus rings visible; nothing themed leaks through.
- `prefers-contrast: more` and `prefers-reduced-transparency: reduce` (Chromium emulation; Safari and Firefox do not support the latter).
- Text size and line spacing changes reflow message text; the sidebar density changes row heights.
- `boot.js` under the production content policy, and the production plugin above.
