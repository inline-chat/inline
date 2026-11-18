# Views and the UI kit

How view code is written, and how our UI kit is built. Read this before writing a `.tsx` file or a UI primitive.

## Where we are going

Solid 2 is the intended view framework. It had no stable release when this was written, so views are React for now, with the React Compiler. The aim is that the move is a port of thin files, not a rewrite: logic, state that matters, navigation and UI behavior live in framework-free TypeScript, and views render.

Before a package starts writing views, run `npm view solid-js dist-tags`. If `latest` is 2.x, write the new views in Solid, and say so in your report so the port of existing views can be planned.

## Rules for React views

Three things are banned in view files, and lint enforces the first two:

1. **No effects.** No `useEffect`, `useLayoutEffect` or `useInsertionEffect`. Subscribing to data goes through the bindings in `reactive`. Wiring a DOM element goes through a ref callback (React 19 ref callbacks can return a cleanup function) or `useElement`. Anything that reacts to time, the network or other state is a view model's job.
2. **No Suspense.** No `Suspense`, `use` or `lazy` for data or code. Loading states are data: a resource in the view store says whether a window is loading. Code splitting is done with dynamic imports in framework-free code.
3. **No heavy context or component state.** Lint cannot check this; reviewers do.
   - Context is for a few stable services (app services, the region's view model). Never put changing data in context.
   - Component state is fine for small things that belong to one view and nobody else cares about: a hover flag, a disclosure that is not restored. If state is shared, persisted, restored after navigation, driven by a keyboard command, or worth a unit test, it belongs on a view model or controller.

Also:

- No React-bound router, data, state or form library. Navigation is ours (`view/workspace`). A small React-only dependency for a view concern needs a recorded reason in `decisions.md`.
- Import React names individually (`import { useState } from "react"`), not as a namespace.

Everything else in ordinary React is allowed. Conditionals, `.map`, destructured props, `useState`, `useRef` and `useId` are fine. The React Compiler handles memoization; do not add `useMemo` or `useCallback` by hand without a measurement.

## Habits that make the port cheap

These are a direction, not rules. Prefer them when they cost nothing.

- Keep a view file about rendering. If a view grows logic, move the logic out and unit-test it there.
- Pass IDs to rows and let each row read its own data through `useSignal`.
- Read `props.x` where it is natural. Solid 2 warns when props are destructured, because that loses reactivity.
- Use camelCase handlers and native event semantics: `onInput` for text as it is typed, `onChange` when a value is committed.
- Do not lean on React-only behavior: synthetic event quirks, `key` to reset state, `children` inspection, class components.
- Style through StyleX only, so the styling layer ports unchanged (`stylex.props` in React, `stylex.attrs` in Solid).
- Give each top-level region (sidebar, each pane, command bar, overlay layer) its own mount point and view model. Regions can then be ported one at a time.

## The UI kit (`ui`)

We own our UI kit. There is no third-party component kit.

- **Tokens.** Color, type, spacing, radius, motion and layers are StyleX variables. Light and dark use `light-dark()`. Views use tokens, never raw values.
- **Two parts per primitive.** A headless controller owns state, keyboard, focus and ARIA. It is framework-free and unit-tested. A thin view renders it.
- **Built on the platform.** The Popover API and top layer, `<dialog>`, and `inert`. No portals for layering. Positioning is our own small function, because CSS anchor positioning is newer than our browser floor.
- **First set.** Button, IconButton, TextField, Menu and ContextMenu, Popover, Tooltip, Dialog and Sheet, Listbox and Combobox, Tabs, Toggle, ScrollArea, SplitView with resizable panes, Toast, Avatar, Badge, Kbd, Progress.
- **UI lab.** A page that renders every primitive in every state. It is the review surface and the source of visual regression screenshots. A primitive is not done until it is in the lab.

Before building a primitive, read the matching WAI-ARIA Authoring Practices pattern and look at how the Mac app behaves for the same control. Where they disagree on feel, follow the Mac app; where it is about assistive technology, follow the pattern.

## Desktop-grade behavior

These are what separate a desktop app from a web page. Treat each as a requirement.

- Every action is a command in the command registry, with a title, a shortcut per platform and an enabled state. Menus, context menus, the command bar and Electron's native menus all read from it.
- Everything is reachable from the keyboard. Focus is always visible for keyboard users and never for pointer users (`:focus-visible`).
- Focus returns to where it was when a menu, dialog or popover closes.
- Secondary click opens a context menu on anything that has actions. Menus have hover intent and a safe triangle for submenus.
- Lists support range selection with Shift and toggling with the platform modifier.
- Drag and drop works for files into the composer and for anything the Mac app lets you drag.
- Text in messages is selectable, across rows.
- Shortcuts follow the platform: Cmd on Mac, Ctrl elsewhere. Never bind a shortcut the browser or the OS owns.
- No layout shift after first paint. Media reserves its size before it loads.
- Motion is short and can be turned off (`prefers-reduced-motion`).

## Accessibility and locale

- ARIA roles and keyboard behavior follow the APG pattern for each primitive.
- Support `prefers-reduced-motion`, `prefers-contrast` and forced colors.
- Right-to-left works from the start: logical properties only, and `dir="auto"` on user-written text.
- Strings are English for now and kept out of logic, so a translation layer can be added later.

## Styling

- StyleX only. Tokens live in `*.stylex.ts` files: today in `web/src/ui`, imported through the `~/` alias; they move into the `ui` package when it is created, and are then imported from it. StyleX has to be told about any alias it resolves token files through (`vite.config.ts`).
- No `<style>` injection at runtime and no style attributes in markup strings; the production CSP forbids both. A dynamic value goes through a StyleX dynamic style or a CSS variable set on the element from code, which the policy allows.
- Global CSS is limited to a few document-level rules in `src/app/global.css` that nothing ever overrides (root height, body margin). StyleX output lives in CSS layers, and unlayered CSS always beats layered CSS, so anything themeable declared in `global.css` silently overrides StyleX. This already bit once: an unlayered `color-scheme` on `:root` made a user's choice of dark mode resolve every `light-dark()` token to its light value. Color scheme, fonts, colors and backgrounds go on the root through StyleX and the appearance controller.
- StyleX collects every page's rules into the app's one stylesheet. A separate HTML entry (a lab page) must link that stylesheet itself in a production build; `tooling/vite.labs.config.ts` does this for labs.
