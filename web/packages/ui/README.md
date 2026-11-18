# @inline/ui

Our UI kit. No third-party component or positioning library. Every primitive has two parts:

- a **controller** in `src/<primitive>/controller.ts`: plain TypeScript, framework-free. It owns state (signals from `@inline/reactive`), keyboard, focus, ARIA and layering, and is unit-tested in Node with happy-dom. Exported from `@inline/ui`.
- a thin **view** in `src/react/`: renders the controller's data and hands DOM elements to it. Exported from `@inline/ui/react`. React today; the views are small so the Solid port is a port of thin files.

The UI lab (`web/lab-ui.html`, source in `web/src/lab/ui/`) renders every primitive in every state, in light, dark and system appearance and in both directions. Start it with `?theme=dark&dir=rtl` for screenshots.

## Primitives

| Primitive | Controller | View | Pattern |
| --- | --- | --- | --- |
| Button, IconButton | none (native `<button>`) | `Button`, `IconButton` (tooltip = accessible name) | APG Button |
| TextField | none (native `<input>`) | `TextField` (label, description, error wired; `invalid` and `describedBy` for an error shown elsewhere) | |
| Menu | `MenuController` | `MenuButton`, `MenuContent` | APG Menu Button, Menu |
| ContextMenu | `ContextMenuController` | `ContextMenuArea` | APG Menu |
| ContextMenu, loaded on first use | `ContextMenuTrigger`, `LazyContextMenu` | `LazyMenuContent` | APG Menu |
| Popover | `PopoverController` | `PopoverContent` | APG Disclosure + dialog role |
| Tooltip | `TooltipController`, `TooltipGroup` | `TooltipContent` | APG Tooltip |
| Dialog, Sheet | `DialogController`, `createSheet` | `Dialog` | APG Dialog (Modal), Alert Dialog |
| Listbox | `ListboxController`, `SelectionModel` | `Listbox` | APG Listbox |
| Combobox | `ComboboxController` | `Combobox` | APG Combobox (list autocomplete) |
| Tabs | `TabsController` | `Tabs` | APG Tabs |
| Toggle, Switch | `ToggleController` | `ToggleButton`, `Switch` | APG Button (toggle), Switch |
| SplitView | `SplitViewController` | `SplitView` | APG Window Splitter |
| Toast | `ToastQueue`, `toastPlacement` | `ToastRegion` | status / alert live regions |
| Kbd, Badge, Avatar, Progress, Separator, ScrollArea | `avatarStyle`, `initials`, `avatarSeed` | same names | |

### Controller API shape

All controllers follow one shape:

- A class, constructed with an options object. `dispose()` closes and releases everything.
- State is exposed as `ReadSignal`s (`isOpen`, `highlightedId`, `selectedId`, `activeId`, `selected`, ...). Views read them with `useSignal`. Per-row state has cached per-ID signals (`isHighlighted(id)`, `isSelected(id)`, `isActive(id)`) so one change re-renders one row.
- Collections are data, not DOM: menus take `MenuEntry[]`, listboxes take `ListboxOption[]`, tabs take `TabSpec[]`, each as a function so it can read signals.
- DOM wiring goes through **parts**: `{ attach(element): Dispose }`. Views pass a part to `useElement`. Parts are cached (`menu.item(id)` returns the same object every time), so a view can call them every render. `combineParts(a, b)` attaches two controllers to one element (a menu trigger with a tooltip). A part sets roles, ARIA, IDs and listeners itself; the view only renders content and styles.
- Imperative methods mirror user intent: `open()`, `close()`, `toggle()`, `select(id)`, `activate(id)`, `handleKeyDown(event)`.
- Time goes through a `Clock` option (`systemClock` by default). Tests use `createManualClock()` and never sleep.

Key exports, by primitive:

- **Menu**: `new MenuController({ items, placement?, loop?, submenuOpenDelay?, submenuGrace?, onAction?, onOpenChange? })`; `trigger`, `content`, `item(id)` parts; `submenu(id)` returns the child controller; `open({ highlight, focus, anchor, returnFocus })`, `close({ restoreFocus })`, `closeAll()`, `activate(id)`, `openSubmenu(id)`, `highlight(id)`. Entries: `item` (with `onSelect`, `shortcut`, `keyshortcuts`, `destructive`, `keepOpen`), `checkbox`, `radio`, `submenu`, `separator`, `label`.
  - **Names and shortcuts** (APG Menu): an item's accessible name is its `label` alone (`aria-label`); the visible shortcut glyphs are `aria-hidden`, and the shortcut is exposed as `aria-keyshortcuts`: `keyshortcuts` when given (build it from the command's combo with `ariaKeyShortcuts({ key, ctrl, meta, alt, shift })`: "Meta+E", "Control+Shift+E"), else read back from the `shortcut` hint when it parses (`ariaKeyShortcutsFromHint`: the registry's "⌘E", "⇧⌘⌫", "Ctrl+Shift+E", "Alt+Up" forms). `IconButton` takes the same pair (`shortcut` shown after the label in its tooltip, `aria-hidden`; `keyshortcuts` on the button, not derived from the hint, so the parser stays in the menu chunk).
- **ContextMenu**: `new ContextMenuController({ items, label, shouldOpen? })`; `target`, `content`, `item(id)` parts; `openAt(x, y)`, `openFor(invocation)`; `.menu` is the underlying `MenuController`. `shouldOpen` gets the `contextmenu` event, or the `keydown` of Shift+F10.
- **ContextMenu, loaded on first use**: rows bind a menu without importing it (see "Menus load on first use" below). `new LazyContextMenu({ ...ContextMenuOptions, kit?, onLoadError? })`; `target` part (a `ContextMenuTrigger`); `controller` (signal: the real `ContextMenuController` once loaded), `isOpen`, `waiting` signals; `openFor(invocation)`, `openAt(rect, { keyboard?, returnFocus? })`, `close()`, `warm()`, `dispose()`. View: `<LazyMenuContent menu={lazy} />`, rendered once anywhere (it renders nothing until the code is there). `new ContextMenuTrigger({ shouldOpen?, onInvoke })` alone gives a `ContextMenuInvocation` (`anchor`, `keyboard`, `target`, `returnFocus`) per request.
- **Popover**: `new PopoverController({ placement?, offset?, arrowSize?, role?, label?, initialFocus?, closeOnFocusOutside?, anchor? })`; `trigger`, `content` parts.
- **Tooltip**: `new TooltipController({ group?, placement? })`; `trigger`, `content` parts. `new TooltipGroup({ delay, skipDelay, clock })`; `defaultTooltipGroup()` is shared app-wide.
- **Dialog**: `new DialogController({ modal?, role?, presentation?, closeOnBackdropPress?, closeOnEscape?, initialFocus?, onClose? })`; `content` (the `<dialog>`), `surface`, `title`, `description` parts; `open()`, `close(reason)`. `createSheet(options)`. Layout (`Dialog` view): a dialog is centered (`margin: auto`, which the shared layer reset removes, so the dialog style restores it); a sheet keeps that but sits at the top (`margin-block-start: 0`); both are `min(480px, 100vw - 32px)` wide and never taller than `100dvh - 32px`: the surface holds the same bound, the header, description and footer keep their size and the body scrolls. Pinned by `src/react/layout-rules.test.ts`.
- **Listbox**: `new ListboxController({ items, selectionMode, selected?, selectionFollowsFocus?, onAction?, platform? })`; `root` and `passiveRoot` (for a combobox popup) parts, `option(id)`; `selection` is a `SelectionModel` (`replace`, `toggle`, `extendTo`, `selectAll`, `clear`, `set`).
- **Combobox**: `new ComboboxController({ items + filter | load, debounce?, selectionMode?, onCommit?, openOnFocus? })`; `input`, `popup` parts, `listbox` (its `passiveRoot` and `option(id)` parts); `query`, `results`, `status` signals.
- **Tabs**: `new TabsController({ tabs, selected?, activation?, orientation? })`; `list`, `tab(id)`, `panel(id)` parts.
- **Toggle**: `new ToggleController({ kind: "button" | "switch", pressed?, disabled?, onChange? })`; `root` part.
- **SplitView**: `new SplitViewController({ panes, orientation?, initial?, onChange?, step? })`; `root`, `pane(id)`, `separator(index)` parts; `size(id)`, `isCollapsed(id)` signals; `state()` returns plain data to persist and `initial` restores it.
- **Toast**: `new ToastQueue({ max?, duration?, clock?, label?, offset? })`; `show(input)` returns an ID (reuse it to replace in place; `input.description` is a second line that wraps), `dismiss(id)`, `pause()`, `resume()`; `region` part; `visible` signal.
  - **Placement comes from the app.** Attach `queue.container` (a part) to the element whose inline-end, block-end corner should hold the toasts, typically the message list above the composer: `<div ref={useElement(shell.toasts.container)}>`. The region sits in that corner, `offset` in from both edges (default `{ inline: 16, block: 16 }`; the app passes what fits its chrome, 12 and 12 for the message list), never wider than the container less the offsets. The newest attached container wins; detaching falls back to the previous one, then to the window's inline-end, block-end corner (right in left-to-right, left in right-to-left, never assumed). It follows the container's size (`ResizeObserver`) and the window's; call `queue.reposition()` after a layout change it cannot see. The region writes `--ui-toast-inset-inline-end`, `--ui-toast-inset-block-end` and `--ui-toast-max-inline-size` on itself; `toastPlacement(rect, viewport, dir, offset)` is the pure rule.
  - **Screen readers.** Each toast's title and description sit in one `role="status"` element (`role="alert"` for the error tone), `aria-atomic`, without the buttons, so a toast is read once, title then description; replacing a toast in place reads it again. Newest last, nearest the corner, as on the Mac.

### Foundations (framework-free, exported from `@inline/ui`)

- `computePosition(input)`: placement (logical sides `inline-start` and `inline-end`, and `start` and `end` alignment that follow direction), offset, flip, `flipAlign`, shift, size (`maxWidth`, `maxHeight`) and arrow. A pure function of rectangles.
- `placeLayer(el, options)` and `trackLayer(el, options)`: measure, compute, and write `left` and `top`, `data-side`, `data-align`, and the CSS variables `--ui-available-width`, `--ui-available-height`, `--ui-arrow-x`, `--ui-arrow-y`; tracking re-places on scroll, resize and content resize.
- `showLayer`, `hideLayer`, `raiseLayer`: the Popover API with `popover="manual"`. `LAYER_ATTRIBUTE` (`data-ui-layer`) marks our layers.
- `pushDismissLayer(document, options)`: the dismissal stack (outside press, Escape, focus leaving) with nesting.
- `activateFocusScope(container, { trap, initialFocus, restoreFocus, finalFocus })`, `getTabbables`, `RovingTabIndex`.
- `createModalityTracker`, `acquireModality`: keyboard, pointer or touch, for behavior (focus rings use `:focus-visible`).
- `Typeahead`, `findTypeaheadMatch`; `navigate` over keyed collections; `HoverIntent` and `safePolygon` for submenus; `createId`, `childId`; `hasCommandModifier` (Cmd on Mac, Ctrl elsewhere). Shortcut matching is `@inline/view`'s.

## Menus load on first use

Menus are not on the first frame. The menu kit chunk (`@inline/ui/menu-kit`, source `src/react/menu-kit.tsx`: `MenuController`, `ContextMenuController` and the `Menu` views) is loaded through one shared holder, `menuKit` (a `Lazy`; `loadMenuKit()` loads it). Rows bind "open a context menu here" with `LazyContextMenu`'s `target` part, which imports none of it:

- A secondary click, the context menu key or Shift+F10 is captured by `ContextMenuTrigger`: the browser's menu is prevented at once (also while the chunk loads), and the request (pointer point, or the target's rectangle and "highlight the first item" for the keyboard, and the element focus returns to) is kept. It is never lost: when the chunk arrives the menu opens exactly as it would have. A second request while loading replaces the first; `close()` drops it; a failed load drops it and calls `onLoadError` (the next request tries again).
- Shift+F10 is also taken from `keydown` (Chromium and Safari on macOS fire no `contextmenu` for it); the `contextmenu` a platform fires after our keydown is swallowed, not a second request.
- Once loaded, requests open synchronously.
- The app warms the chunk on the idle lane: in `src/app/view-chunks.ts`, `menus: () => import("@inline/ui/menu-kit")` in `chunkImporters` and `"menus"` in `afterFirstPaint` (the same specifier, so it is one chunk). `menuKit` then resolves on its first use a microtask later; `lazy.warm()` makes a given menu's first open synchronous.

## Invariants

- **No portals.** Layers render where they are declared and go to the top layer through the Popover API (`popover="manual"`) or `<dialog>.showModal()`. A submenu's content renders inside its parent menu's content, as a sibling of its item, not inside the item.
- **One owner for dismissal.** Platform light dismiss is never used. The dismiss stack decides: Escape closes the topmost layer only; an outside press closes layers from the top until it reaches the layer that contains the press (a press in a menu closes its submenu only); a press on a layer's trigger (or an ancestor's trigger) is left to the trigger's own handler.
- **Focus returns** to where it was when a menu, popover or dialog closes, unless the user already moved focus elsewhere. Activating a menu item closes the menu (restoring focus) before running the handler, so a dialog it opens returns focus to the menu's trigger.
- **Menus are keyboard complete**: arrows (no wrap, like macOS; `loop: true` to wrap), Home, End, PageUp, PageDown, typeahead (Space is a character mid-search), Enter and Space activate, the inline-end arrow opens a submenu, the inline-start arrow and Escape close one level, Tab closes all and moves on.
- **Hover intent**: a submenu opens after 100ms of hover; while the pointer travels from its item toward it inside the safe triangle and keeps moving, crossing other items changes nothing; resting for 300ms or leaving the triangle applies the item under the pointer.
- **Tooltips** never open on touch or on pointer focus; they open at once on keyboard focus, and at once on hover while a neighbor in the group is showing or just closed.
- **Right to left**: arrows, submenu sides, `start` and `end` alignment, splitter keys and drags all follow the `dir` in effect. Views use logical properties only; the one exception is the popover arrow, whose offset comes from the positioning function in physical pixels.
- **Desktop selection**: click replaces, the platform modifier toggles, Shift extends a range from the anchor (added to the selection the anchor was set on), Cmd+A or Ctrl+A selects all.
- **Styling**: StyleX and tokens only; focus rings only for `:focus-visible`; every motion duration is 0ms under `prefers-reduced-motion`, and infinite animations (the spinner, the indeterminate bar) stop; separators and borders strengthen under `prefers-contrast: more`.
- No raw HTML sinks; styles are set from code (CSSOM) or StyleX, which the production content policy allows.

## Tokens

`src/tokens/*.stylex.ts`, one `defineVars` group per file: `color`, `font`, `space`, `size`, `radius`, `motion`, `layer`, `shadow`. Color values use `light-dark()`, so they follow the document's (or an element's) `color-scheme`. Names follow the macOS semantic colors the Mac app draws with (`label`, `secondaryLabel`, `separator`, `selectedContentBackground`, `unemphasizedSelectedContentBackground`, ...) and the Mac app's Theme (`accent` and `prominent` from the "System" preset of `apple/InlineUI/Sources/InlineTheme/ThemeCatalog.swift`, `iconGray`, `titleTextGray`, `composeOutline`, `bubble`, `secondaryBubble`). Sizes and radii come from `apple/InlineMacUI/Sources/MacTheme/Theme.swift` (sidebar 180 to 340, item radius 10, toolbar 46, bubble radius 14) and AppKit control sizes; type sizes are the macOS text styles (body 13). Avatar colors and hashing match `InlineAvatarStyle` in `apple/InlineKit`.

Themes, appearance, message text and sidebar density: see `src/theme/README.md`. The Mac app's eight themes are `stylex.createTheme` classes over `color` and `themeColor`, applied with `color-scheme` and density classes by `AppearanceController` (`@inline/ui/theme`, framework-free; StyleX binding in `@inline/ui/theme/stylex`; views `AppearanceSwitch`, `ThemeSwatchGrid`, `TextSizeStepper` and others in `@inline/ui/react`). Added token groups: `chatText` (message font, size, line height, emoji sizes), `density` (sidebar rows), `themeColor` (bubble link, reply pane). `color` gained forced-colors and reduced-transparency conditions only. Lab: `web/lab-theme.html`.

`web/src/ui/tokens.stylex.ts` still serves the app shell. Mapping when it moves over: `textPrimary` to `color.label`, `textSecondary` to `color.secondaryLabel`, `windowBackground`, `sidebarBackground` and `separator` keep their names, `size.sidebarWidth` (280 there, 240 here as on Mac), `titleBarHeight` (44) to `size.toolbar` (46).

## StyleX: what the app build needs

Checked by compiling every view, token and lab file with `@stylexjs/babel-plugin` 0.19.1 (`unstable_moduleResolution: { type: "commonJS", rootDir: web/ }`): all compile, 600 rules.

1. Inside the package, token files are imported by relative path, which StyleX resolves without configuration. The Vite plugin must transform files under `web/packages/ui/src`; it does when Vite resolves the workspace link to its real path (the default, `resolve.preserveSymlinks: false`). Nothing to add for that.
2. To import tokens by package name (`@inline/ui/tokens/color.stylex`, exported in `package.json`), add to the StyleX plugin's `aliases` in `web/vite.config.ts`: `"@inline/ui/tokens/*": [\`${webRoot}/packages/ui/src/tokens/*\`]`. Until then, app code imports them by relative path, as the lab does.
3. Keyframes are file-local: each view declares its own `stylex.keyframes`. Importing a keyframes value from another plain file fails to compile.
4. `lab-ui.html` is served by the dev server as is. Add it to `build.rollupOptions.input` if the lab should exist in production builds.
5. View-level tests need the StyleX compiler in Vitest (StyleX throws at runtime without it): add the StyleX Vite plugin to this package's `vitest.config.ts`, which needs `@stylexjs/unplugin` available to the package.

## Adding a primitive

1. Read the APG pattern and look at the Mac app's equivalent. Where they disagree on feel, follow the Mac app; for assistive technology, follow the pattern.
2. Write the controller in `src/<name>/controller.ts` with the shape above: options in, signals out, cached parts, a `Clock` for any delay, `dispose()`. Use the foundations; do not add a second dismissal, focus or positioning mechanism.
3. Write `src/<name>/controller.test.ts` with `// @vitest-environment happy-dom`, building fixtures with `h` and driving them with `keydown`, `press`, `pointer` and `click` from `src/testing/dom.ts`. Cover every key binding, focus on open and close, ARIA attributes, outside press, and right to left. No sleeps.
4. Write the view in `src/react/`: render, attach parts with `useElement`, read signals with `useSignal`, create controllers with `useModel`. No effects, no Suspense, no portals, StyleX and tokens only, logical properties only.
5. Export both, add a lab section with every state labelled, and update this README.

## Tests

`bun run test` from this package: 23 files, 220 tests (72 of them theming, in `src/theme/`), in Node with happy-dom where a DOM is needed. They cover the foundations (positioning, dismissal nesting, focus scopes and traps, roving tab index, modality, typeahead, hover intent, the manual clock, `aria-keyshortcuts`) and every controller's keyboard, focus, pointer and ARIA behavior, the lazy context menu with a loader that resolves late (a secondary click and the context menu key before the chunk arrives, Shift+F10, a second request, `close()` while waiting, a failed load), toast placement, and the dialog, sheet and toast layout rules read from the views' StyleX source (`readStylexStyles` in `src/theme/stylex-source.ts`). Browser-only behavior (real top layer, `showModal` inertness, layout, `:focus-visible`) needs the component tests in a real browser that `docs/testing.md` assigns to this package.
